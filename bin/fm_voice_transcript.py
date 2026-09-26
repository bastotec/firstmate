"""fm_voice_transcript.py - read the first mate's own conversation for Ziggy.

The first mate is a pi session whose transcript pi writes as JSONL under
~/.pi/agent/sessions/<cwd as --a-b-c-->/<started>_<id>.jsonl. Ziggy reads it
here, read-only, to answer "what were we just talking about?" without asking
the first mate: the latest exchanges, or a search across recent sessions.

Only what the captain and the first mate SAID is read: user text and
assistant text. Thinking, tool calls and tool output are skipped, and so are
injected skill bodies.

Search is hybrid: a keyword ranking (BM25 over each message) and a meaning
ranking (cosine over bge-small-en-v1.5 embeddings, run locally with
onnxruntime) fused with Reciprocal Rank Fusion, so an exact name and a
paraphrase both find their message. Embeddings are cached per session file
under ~/.cache/fm-voice/transcript-index and only new messages are embedded;
until the model or the index is ready, search is keyword-only.
"""

import glob
import hashlib
import json
import math
import os
import re
import threading

SESSIONS = os.path.expanduser("~/.pi/agent/sessions")
SNIPPET_CHARS = 500
RECENT_MAX_CHARS = 6000
SEARCH_SESSIONS = 6            # newest sessions searched
WORD = re.compile(r"[a-z0-9][a-z0-9_.-]*", re.I)
STOP = set("the a an and or of to in on for is are was were be it this that with as at by "
           "from i you we they he she me my our your do did does what how why when "
           "can could would should will just about".split())

_cache = {}                    # path -> (mtime, size, messages)

EMBED_REPO = "Xenova/bge-small-en-v1.5"
EMBED_MAX_TOKENS = 256
QUERY_PREFIX = "Represent this sentence for searching relevant passages: "
INDEX_DIR = os.path.expanduser("~/.cache/fm-voice/transcript-index")
RRF_K = 60
RANK_DEPTH = 50                # how deep each ranking goes into the fusion


def session_dir(home):
    """pi's folder for sessions started in `home`."""
    return os.path.join(SESSIONS, "--" + os.path.abspath(home).strip("/").replace("/", "-") + "--")


def sessions(home):
    """The first mate's session files, newest first."""
    return sorted(glob.glob(os.path.join(session_dir(home), "*.jsonl")),
                  key=os.path.getmtime, reverse=True)


def _text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content
                         if isinstance(p, dict) and p.get("type") == "text")
    return ""


def messages(path):
    """[(timestamp, role, text)] for what the captain and the first mate said."""
    stat = os.stat(path)
    cached = _cache.get(path)
    if cached and cached[0] == stat.st_mtime and cached[1] == stat.st_size:
        return cached[2]
    out = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if entry.get("type") != "message":
                continue
            message = entry.get("message") or {}
            role = message.get("role")
            if role not in ("user", "assistant"):
                continue
            text = _text(message.get("content")).strip()
            if not text or text.startswith("<skill "):
                continue
            out.append((entry.get("timestamp", ""), "captain" if role == "user" else "first mate", text))
    _cache[path] = (stat.st_mtime, stat.st_size, out)
    return out


def _local(stamp):
    """pi's UTC ISO stamp as the captain's local 'Fri 25 Sep 14:59'."""
    import datetime
    try:
        at = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return stamp
    return at.astimezone().strftime("%a %d %b %H:%M")


def _clip(text, limit=SNIPPET_CHARS, around=None):
    text = " ".join(text.split())
    if len(text) <= limit:
        return text
    start = 0
    if around is not None:
        start = max(0, min(around - limit // 3, len(text) - limit))
    return ("..." if start else "") + text[start:start + limit] + "..."


def recent(home, count=8):
    """The last `count` things said in the first mate's current session."""
    files = sessions(home)
    if not files:
        return {"error": "no first mate session found under " + session_dir(home)}
    said = messages(files[0])[-max(1, min(int(count), 30)):]
    items, total = [], 0
    for stamp, who, text in reversed(said):
        line = {"at": _local(stamp), "who": who, "said": _clip(text)}
        total += len(line["said"])
        if items and total > RECENT_MAX_CHARS:
            break
        items.append(line)
    return {"session": os.path.basename(files[0]), "messages": list(reversed(items))}


def _terms(text):
    return [w.lower() for w in WORD.findall(text) if w.lower() not in STOP]


class Embedder:
    """bge-small-en-v1.5 on onnxruntime: CLS pooling, unit vectors."""

    def __init__(self):
        from huggingface_hub import hf_hub_download   # noqa: PLC0415
        import onnxruntime                              # noqa: PLC0415
        from tokenizers import Tokenizer                # noqa: PLC0415
        model = hf_hub_download(EMBED_REPO, "onnx/model.onnx", local_files_only=True)
        tok = hf_hub_download(EMBED_REPO, "tokenizer.json", local_files_only=True)
        self.tokenizer = Tokenizer.from_file(tok)
        self.tokenizer.enable_truncation(EMBED_MAX_TOKENS)
        self.tokenizer.enable_padding()
        options = onnxruntime.SessionOptions()
        options.intra_op_num_threads = 2          # stay light next to the voice stack
        self.session = onnxruntime.InferenceSession(model, options,
                                                    providers=["CPUExecutionProvider"])
        self.inputs = {i.name for i in self.session.get_inputs()}

    def __call__(self, texts):
        import numpy as np                              # noqa: PLC0415
        out = []
        for i in range(0, len(texts), 32):
            enc = self.tokenizer.encode_batch(texts[i:i + 32])
            feed = {"input_ids": np.array([e.ids for e in enc], dtype=np.int64),
                    "attention_mask": np.array([e.attention_mask for e in enc], dtype=np.int64)}
            if "token_type_ids" in self.inputs:
                feed["token_type_ids"] = np.array([e.type_ids for e in enc], dtype=np.int64)
            cls = self.session.run(None, feed)[0][:, 0]
            out.append(cls / np.linalg.norm(cls, axis=1, keepdims=True))
        return np.concatenate(out) if out else np.zeros((0, 384), dtype=np.float32)


_embedder = None
_embed_lock = threading.Lock()


def embedder():
    """The shared embedder, or None when the model is not installed."""
    global _embedder
    with _embed_lock:
        if _embedder is None:
            try:
                _embedder = Embedder()
            except Exception:                           # noqa: BLE001
                _embedder = False
        return _embedder or None


def vectors(path, embed):
    """Unit vectors for every message of one session, embedding only the
    messages added since the cached index was written."""
    import numpy as np                                  # noqa: PLC0415
    said = messages(path)
    os.makedirs(INDEX_DIR, exist_ok=True)
    key = hashlib.sha1(os.path.abspath(path).encode()).hexdigest()[:16]
    index = os.path.join(INDEX_DIR, key + ".npy")
    have = None
    if os.path.exists(index):
        try:
            have = np.load(index)
        except (OSError, ValueError):
            have = None
    if have is not None and len(have) > len(said):   # the file was rewritten
        have = None
    done = 0 if have is None else len(have)
    if done < len(said):
        new = np.asarray(embed([text for _, _, text in said[done:]]), dtype=np.float32)
        have = new if have is None else np.concatenate([have, new])
        tmp = index + ".tmp.npy"
        np.save(tmp, have)
        os.replace(tmp, index)
    return have if have is not None else np.zeros((0, 1), dtype=np.float32)


_warmed = set()


def warm(home):
    """Build the embedding index in the background, so the first search is fast."""
    if home in _warmed:
        return
    _warmed.add(home)

    def run():
        embed = embedder()
        if embed is None:
            return
        for path in sessions(home)[:SEARCH_SESSIONS]:
            try:
                vectors(path, embed)
            except Exception:                           # noqa: BLE001
                pass
    threading.Thread(target=run, name="transcript-index", daemon=True).start()


def search(home, query, count=5, embed=None):
    """Messages across the newest sessions ranked against `query`: BM25 and
    embedding similarity fused with Reciprocal Rank Fusion (keyword-only
    without the embedding model)."""
    q = _terms(query)
    if not q and not query.strip():
        return {"error": "search needs a query"}
    docs, paths = [], sessions(home)[:SEARCH_SESSIONS]
    for path in paths:
        for stamp, who, text in messages(path):
            docs.append((stamp, who, text, _terms(text)))
    if not docs:
        return {"error": "no first mate session found under " + session_dir(home)}
    keyword = _bm25(q, docs)
    meaning = []
    embed = embed if embed is not None else embedder()
    if embed is not None:
        try:
            import numpy as np                          # noqa: PLC0415
            matrix = np.concatenate([m for m in (vectors(p, embed) for p in paths) if len(m)])
            if len(matrix) == len(docs):
                sims = matrix @ embed([QUERY_PREFIX + query])[0]
                meaning = [int(i) for i in np.argsort(-sims)[:RANK_DEPTH]]
        except Exception:                               # noqa: BLE001
            meaning = []
    fused = {}
    for ranking in (keyword[:RANK_DEPTH], meaning):
        for rank, i in enumerate(ranking):
            fused[i] = fused.get(i, 0.0) + 1.0 / (RRF_K + rank + 1)
    order = sorted(fused, key=fused.get, reverse=True)
    hits = []
    for i in order[:max(1, min(int(count), 10))]:
        stamp, who, text, _ = docs[i]
        lower = text.lower()
        at = min((lower.find(t) for t in q if lower.find(t) >= 0), default=0)
        hits.append({"at": _local(stamp), "who": who, "said": _clip(text, around=at)})
    return {"query": query, "ranking": "hybrid" if meaning else "keyword", "hits": hits}


def _bm25(q, docs):
    """Indexes of `docs` matching the query terms, best first."""
    n = len(docs)
    avg = sum(len(d[3]) for d in docs) / n
    df = {}
    for d in docs:
        for term in set(d[3]):
            df[term] = df.get(term, 0) + 1
    scored = []
    for index, d in enumerate(docs):
        tf = {}
        for term in d[3]:
            tf[term] = tf.get(term, 0) + 1
        score = 0.0
        for term in set(q):
            if term not in tf:
                continue
            idf = math.log(1 + (n - df[term] + 0.5) / (df[term] + 0.5))
            f = tf[term]
            score += idf * f * 2.2 / (f + 1.2 * (0.25 + 0.75 * len(d[3]) / avg))
        if score > 0:
            scored.append((score, index))
    scored.sort(key=lambda s: s[0], reverse=True)
    return [index for _, index in scored]
