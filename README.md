# GitLab Synchronization Script

This project provides a script able to recursively copy/synchronize a GitLab group from one GitLab server to another.

It can be run manually (command line) and also as scheduled CI/CD job to regularly synchronize a GitLab group mirror.

## Pre-requisites

The GitLab Synchronization Script has the following requirements:

* Bash interpreter <br/>_Trivial on Linux or MacOS, tested with [Git Bash](https://www.atlassian.com/git/tutorials/git-bash) on Windows (available in [Git for Windows](https://gitforwindows.org/))_
* [curl tool](https://curl.se/) installed and accessible as `curl` command from the Bash interpreter
* [jq tool](https://stedolan.github.io/jq/download/) installed and accessible as `jq` command from the Bash interpreter

## Usage: script

```bash
gitlab-sync.sh \
   [--src-api {GitLab source API url}] \
   [--src-token {GitLab source token}] \
   [--src-sync-path {GitLab source root group path to synchronize}] \
   --dest-api {GitLab destination API url} \
   --dest-token {GitLab destination token} \
   [--dest-sync-path {GitLab destination root group path to synchronize}] \
   [--max-visibility {max visibility}] \
   [--exclude {coma separated list of project/group path(s) to exclude}] \
   [--no-group-description {do not synchronise group description}] \
   [--no-project-description {do not synchronise project description}]
```

| CLI option            | Env. Variable        | Description                            | Default Value     |
| --------------------- | -------------------- | -------------------------------------- | ----------------- |
| `--src-api`           | `$SRC_GITLAB_API`    | GitLab source API url                  | `https://gitlab.com/api/v4` |
| `--src-token`         | `$SRC_TOKEN`         | GitLab source token (_optional_ if source GitLab group and sub projects have `public` visibility) | _none_ |
| `--src-sync-path`     | `$SRC_SYNC_PATH`     | GitLab source root group path to synchronize  | `to-be-continuous` |
| `--dest-api`          | `$DEST_GITLAB_API`   | GitLab destination API url (**mandatory**) | `$CI_API_V4_URL` (defined when running in GitLab CI) |
| `--dest-token` | `$DEST_TOKEN` or `$GITLAB_TOKEN` | GitLab destination token with at least scopes `api,read_repository,write_repository` and `Owner` role (**mandatory**) | _none_ |
| `--dest-sync-path`    | `$DEST_SYNC_PATH`    | GitLab destination root group path to synchronize  | `to-be-continuous` |
| `--max-visibility`    | `$MAX_VISIBILITY`    | maximum visibility of projects in destination group | `public` |
| `--exclude`           | `$EXCLUDE`           | coma separated list of project/group path(s) to exclude | _none_ |
| `--no-group-description` | `$GROUP_DESCRIPTION_DISABLED` | do not synchronise group description | _none_|
| `--no-project-description` | `$PROJECT_DESCRIPTION_DISABLED` | do not synchronise project description | _none_|

You shall use this script to copy the _to be continuous_ project to your own GitLab server for the first time with the following command:

```bash
curl -s https://gitlab.com/to-be-continuous/tools/gitlab-sync/-/raw/master/gitlab-sync.sh | bash /dev/stdin --dest-api {your GitLab server API url} --dest-token {your GitLab token} --exclude samples,custom
```

:warning: Each CLI option may alternately be specified with an environment variable (see in the table above). This might be useful to configure the CI/CD job.

## Usage: CI/CD

Once copied _to be continuous_ to your GitLab server, you shall then schedule a pipeline in this project (`to-be-continuous/tools/gitlab-sync`) - for instance every night - to keep synchronized with source project.

The script will only require a GitLab token, that shall be configured declaring a `$GITLAB_TOKEN` CI/CD project variable. (`--dest-api` will be implicitly retrieved using predefined `$CI_API_V4_URL`).
