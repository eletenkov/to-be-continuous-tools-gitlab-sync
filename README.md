# GitLab Synchronization Script

This project provides a script able to recursively copy/synchronize a GitLab group from one GitLab server to another.

It can be run manually (command line) and also as scheduled CI/CD job to regularly synchronize a GitLab group mirror.

## Usage: script

```bash
gitlab-sync.sh \
   --sync-path {GitLab root group path to synchronize} \
   --src-api {GitLab source API url} [--src-token {GitLab source token}] \
   --dest-api {GitLab destination API url} [--dest-token {GitLab destination token}] \
   [--max-visibility {max visibility}] \
   [--exclude {coma separated list of project/group path(s) to exclude}]
```

| CLI option / env. variable        | description                            | default value     |
| --------------------------------- | -------------------------------------- | ----------------- |
| `--sync-path` / `$SYNC_PATH`      | GitLab root group path to synchronize  | `to-be-continuous` |
| `--src-api` / `$SRC_GITLAB_API`   | GitLab source API url                  | `https://gitlab.com/api/v4` |
| `--src-token` / `$SRC_TOKEN`      | GitLab source token (_optional_ if source GitLab group and sub projects have `public` visibility) | _none_ |
| `--dest-api` / `$DEST_GITLAB_API` | GitLab destination API url (**mandatory**) | `$CI_API_V4_URL` (defined when running in GitLab CI) |
| `--dest-token` / `$DEST_TOKEN` or `$GITLAB_TOKEN` | GitLab destination token (**mandatory**) | _none_ |
| `--max-visibility` / `$MAX_VISIBILITY` | maximum visibility of projects in destination group | `public` |
| `--exclude` / `$EXCLUDE`          | coma separated list of project/group path(s) to exclude | _none_ |

You shall use this script to copy the _to be continuous_ project to your own GitLab server for the first time with the following command:

```bash
curl -s https://gitlab.com/to-be-continuous/tools/gitlab-sync/-/raw/master/gitlab-sync.sh | bash /dev/stdin --dest-api {your GitLab server API url} --dest-token {your GitLab token} --exclude samples,custom
```

:warning: Each CLI option may alternately be specified with an environment variable (see in the table above). This might be useful to configure the CI/CD job.

## Usage: CI/CD

Once copied _to be continuous_ to your GitLab server, you shall then schedule a pipeline in this project (`to-be-continuous/tools/gitlab-sync`) - for instance every night - to keep synchronized with source project.

The script will only require a GitLab token, that shall be configured declaring a `$GITLAB_TOKEN` CI/CD project variable. (`--dest-api` will be implicitly retrieved using predefined `$CI_API_V4_URL`).
