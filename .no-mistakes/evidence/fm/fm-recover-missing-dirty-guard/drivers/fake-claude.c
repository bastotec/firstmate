#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--version") == 0 || strcmp(argv[i], "-v") == 0) {
      printf("2.1.220 (Claude Code)\n");
      return 0;
    }
  }
  fprintf(stderr, "fake-claude: running\n");
  for (;;) sleep(3600);
  return 0;
}
