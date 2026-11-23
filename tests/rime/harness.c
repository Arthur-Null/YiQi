// C2: 用真实的 Rime 引擎驱动输入方式，供 test_switch.py 校验小鹤双拼、全拼与切换。
// C2: 每行一条命令：keys <按键序列> | schema | cands | commit | option <名> <0|1> | newsession
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <rime_api.h>

int main(int argc, char **argv) {
  if (argc < 3) return 2;
  RimeApi *api = rime_get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.prebuilt_data_dir = argv[1];
  traits.staging_dir = argv[3] ? argv[3] : argv[2];
  traits.app_name = "rime.qi.test";
  traits.min_log_level = getenv("RIME_LOG") ? 0 : 2;
  api->setup(&traits);
  api->initialize(&traits);
  if (argc > 4 && strcmp(argv[4], "deploy") == 0) {
    api->start_maintenance(True);
    api->join_maintenance_thread();
  }
  RimeSessionId s = api->create_session();
  char line[4096];
  while (fgets(line, sizeof line, stdin)) {
    line[strcspn(line, "\n")] = 0;
    if (strncmp(line, "keys ", 5) == 0) {
      api->simulate_key_sequence(s, line + 5);
      printf("ok\n");
    } else if (strcmp(line, "schema") == 0) {
      char buf[128] = {0};
      api->get_current_schema(s, buf, sizeof buf);
      printf("%s\n", buf);
    } else if (strcmp(line, "cands") == 0) {
      RIME_STRUCT(RimeContext, ctx);
      api->get_context(s, &ctx);
      for (int i = 0; i < ctx.menu.num_candidates; i++)
        printf("%s%s", i ? "|" : "", ctx.menu.candidates[i].text);
      printf("\n");
      api->free_context(&ctx);
    } else if (strcmp(line, "commit") == 0) {
      RIME_STRUCT(RimeCommit, c);
      if (api->get_commit(s, &c)) { printf("%s\n", c.text); api->free_commit(&c); }
      else printf("\n");
    } else if (strncmp(line, "option ", 7) == 0) {
      char name[64]; int v = 0;
      sscanf(line + 7, "%63s %d", name, &v);
      api->set_option(s, name, v);
      printf("ok\n");
    } else if (strcmp(line, "newsession") == 0) {
      s = api->create_session();
      printf("ok\n");
    }
    fflush(stdout);
  }
  api->finalize();
  return 0;
}
