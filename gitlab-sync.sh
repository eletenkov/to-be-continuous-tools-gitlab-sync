#!/usr/bin/env bash
# =========================================================================================
# Copyright (C) 2021 Orange & contributors
#
# This program is free software; you can redistribute it and/or modify it under the terms
# of the GNU Lesser General Public License as published by the Free Software Foundation;
# either version 3 of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
# without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License along with this
# program; if not, write to the Free Software Foundation, Inc., 51 Franklin Street, Fifth
# Floor, Boston, MA  02110-1301, USA.
# =========================================================================================

set -e

function log_info() {
  >&2 echo -e "[\\e[1;94mINFO\\e[0m] $*"
}

function log_warn() {
  >&2 echo -e "[\\e[1;93mWARN\\e[0m] $*"
}

function log_error() {
  >&2 echo -e "[\\e[1;91mERROR\\e[0m] $*"
}

function fail() {
  log_error "$@"
  exit 1
}

function assert_defined() {
  if [[ -z "$1" ]]
  then
    fail "$2"
  fi
}

function init_git() {
  if [[ "$GITLAB_USER_NAME" ]] && [[ "$GITLAB_USER_EMAIL" ]]
  then
    git config --global user.name "$GITLAB_USER_NAME"
    git config --global user.email "$GITLAB_USER_EMAIL"
  fi
}

function adjust_visibility() {
  local visi=$1
  case "$MAX_VISIBILITY" in
  public)
    echo "$visi"
  ;;
  internal)
    if [[ "$visi" == "public" ]]; then echo "internal"; else echo "$visi"; fi
  ;;
  private)
    echo "private"
  ;;
  esac
}

function maybe_create_group() {
  local group_path=$1
  if [[ "$group_path" == "." ]]
  then
    echo "null"
  else
    group_id=${group_path//\//%2f}
    group_status=$(curl ${INSECURE+-k} -s -o /dev/null -I -w "%{http_code}" -H "${DEST_TOKEN+PRIVATE-TOKEN: $DEST_TOKEN}" "$DEST_GITLAB_API/groups/$group_id")
    if [[ "$group_status" == 404* ]]
    then
      # group does not exist: create
      # retrieve parent
      group_name=$(basename "$group_path")
      parent_path=$(dirname "$group_path")
      log_info "... group \\e[33;1m$group_path\\e[0m not found: create group \\e[33;1m$group_name\\e[0m with parent \\e[33;1m$parent_path\\e[0m"
      parent_id=$(maybe_create_group "$parent_path")
      # then create group
      group_json=$(curl ${INSECURE+-k} -sSf -H "${DEST_TOKEN+PRIVATE-TOKEN: $DEST_TOKEN}" -H "Content-Type: application/json" -X POST "$DEST_GITLAB_API/groups" \
        --data "{
          \"name\": \"$group_name\",
          \"path\": \"$group_name\",
          \"visibility\": \"$MAX_VISIBILITY\",
          \"parent_id\": $parent_id
        }")
    elif [[ "$group_status" == 200* ]]
    then
      # group exists: retrieve ID
      log_info "... group \\e[33;1m$group_path\\e[0m found: retrieve ID"
      group_json=$(curl ${INSECURE+-k} -sSf -H "${DEST_TOKEN+PRIVATE-TOKEN: $DEST_TOKEN}" "$DEST_GITLAB_API/groups/$group_id")
    else
      # another error: abort
      fail "... unexpected error while getting group \\e[33;1m$group_path\\e[0m: $group_status"
    fi
  fi

  echo "$group_json" | jq -r '.id'
}

# Synchronizes a GitLab project
# $1: source project JSON
# $2: destination parent group ID (number)
function sync_project() {
  local src_project_json=$1
  src_project_full_path=$(echo "$src_project_json" | jq -r '.path_with_namespace')
  src_main_branch=$(echo "$src_project_json" | jq -r '.default_branch')
  local dest_parent_id=$2
  src_project_id=${src_project_full_path//\//%2f}
  local dest_group_full_path=$3
  dest_project_full_path=${src_project_full_path/$SRC_SYNC_PATH/$DEST_SYNC_PATH}
  dest_project_id=${dest_project_full_path//\//%2f}
  log_info "Synchronizing project \\e[33;1m${src_project_full_path}\\e[0m to \\e[33;1m${dest_project_full_path}\\e[0m (parent group ID \\e[33;1m${dest_parent_id:-none (dry run)}\\e[0m)"
  # dump project json (for debug)
  echo "$src_project_json" > "project-$src_project_id.json"

  # 1: sync project
  if [[ "$DEST_GITLAB_API" ]]
  then
    dest_visibility=$(adjust_visibility "$(echo "$src_project_json" | jq -r .visibility)")
    dest_project_status=$(curl ${INSECURE+-k} -s -o /dev/null -I -w "%{http_code}" -H "${DEST_TOKEN+PRIVATE-TOKEN: $DEST_TOKEN}" "$DEST_GITLAB_API/projects/$dest_project_id")
    if [[ "$dest_project_status" == 404* ]]
    then
      # dest project does not exist: create (disable MR and issues as they are cloned projects)
      log_info "... destination project not found: create with visibility \\e[33;1m${dest_visibility}\\e[0m"
      dest_project_json=$(curl ${INSECURE+-k} -sSf -H "${DEST_TOKEN+PRIVATE-TOKEN: $DEST_TOKEN}" -H "Content-Type: application/json" -X POST "$DEST_GITLAB_API/projects" \
        --data "{
          \"path\": $(echo "$src_project_json" | jq .path),
          \"name\": $(echo "$src_project_json" | jq .name),
          \"visibility\": \"$dest_visibility\",
          \"description\": $(echo "$src_project_json" | jq .description),
          \"namespace_id\": $dest_parent_id,
          \"issues_access_level\": \"disabled\",
          \"merge_requests_access_level\": \"disabled\"
        }")
    elif [[ "$dest_project_status" == 200* ]]
    then
      # dest group exists: sync
      log_info "... destination project found: synchronize"
      if [[ "${PROJECT_DESCRIPTION_DISABLED}" == "true" ]]
      then
        dest_project_json=$(curl ${INSECURE+-k} -sSf -H "${DEST_TOKEN+PRIVATE-TOKEN: $DEST_TOKEN}" -H "Content-Type: application/json" -X PUT "$DEST_GITLAB_API/projects/$dest_project_id" \
          --data "{
            \"name\": $(echo "$src_project_json" | jq .name),
            \"visibility\": \"$dest_visibility\"
          }")
      else
        dest_project_json=$(curl ${INSECURE+-k} -sSf -H "${DEST_TOKEN+PRIVATE-TOKEN: $DEST_TOKEN}" -H "Content-Type: application/json" -X PUT "$DEST_GITLAB_API/projects/$dest_project_id" \
          --data "{
            \"name\": $(echo "$src_project_json" | jq .name),
            \"visibility\": \"$dest_visibility\",
            \"description\": $(echo "$src_project_json" | jq .description)
          }")
      fi
        # \"visibility\": \"$(echo "$src_project_json" | jq -r .visibility)\",
      dest_latest_commit=$(curl ${INSECURE+-k} -sSf -H "${DEST_TOKEN+PRIVATE-TOKEN: $DEST_TOKEN}" "$DEST_GITLAB_API/projects/$dest_project_id/repository/commits?ref_name=$src_main_branch&per_page=1" | jq -r '.[0].id')
    else
      # another error: abort
      fail "... unexpected error: $dest_project_status"
    fi

    # set/update avatar url
    src_avatar_url=$(echo "$src_project_json" | jq -r .avatar_url)
    src_web_url=$(echo "$src_project_json" | jq -r .web_url)
    dest_avatar_url=$(echo "$dest_project_json" | jq -r .avatar_url)
    if [[ "$src_avatar_url" != "null" ]] && [[ "$src_avatar_url" != "${src_web_url}/-/avatar" ]] && [[ "$(basename "$src_avatar_url")" != "$(basename "$dest_avatar_url")" ]]
    then
      log_info "... update avatar image ($src_avatar_url)"
      avatar_filename=/tmp/$(basename "$src_avatar_url")
      curl ${INSECURE+-k} -sSfL --output "$avatar_filename" "$src_avatar_url"
      dest_project_json=$(curl ${INSECURE+-k} -sSf -H "${DEST_TOKEN+PRIVATE-TOKEN: $DEST_TOKEN}" --form "avatar=@$avatar_filename" -X PUT "$DEST_GITLAB_API/projects/$dest_project_id")
    fi
  fi

  # if project already exists: unprotect master branch first
  if [[ "$dest_project_status" == 200* ]]
  then
    log_info "... unprotect $src_main_branch branch (allow failure)"
    curl ${INSECURE+-k} -sS -H "${DEST_TOKEN+PRIVATE-TOKEN: $DEST_TOKEN}" -X DELETE "$DEST_GITLAB_API/projects/$dest_project_id/protected_branches/$src_main_branch" > /dev/null
  fi

  # 2: sync Git repository
  if [[ "$DEST_GITLAB_API" ]]
  then
    src_latest_commit=$(curl ${INSECURE+-k} -sSf -H "${SRC_TOKEN+PRIVATE-TOKEN: $SRC_TOKEN}" "$SRC_GITLAB_API/projects/$src_project_id/repository/commits?ref_name=$src_main_branch&per_page=1" | jq -r '.[0].id')
    if [[ "$src_latest_commit" == "$dest_latest_commit" ]]
    then
      log_info "... source and destination repositories are on same latest commit ($src_latest_commit): skip sync"
    else
      repo_name="$src_project_id"
      rm -rf "$repo_name"

      src_repo_url=$(echo "$src_project_json" | jq -r .http_url_to_repo)
      log_info "... cloning source repository ($src_repo_url)"
      if [[ "$SRC_TOKEN" ]]; then
        # insert login/password in Git https url
        # shellcheck disable=SC2001
        src_repo_url=$(echo "$src_repo_url" | sed -e "s|://|://token:${SRC_TOKEN}@|")
      fi
      git clone --bare "$src_repo_url" "$repo_name"

      cd "$repo_name"
      dest_repo_url=$(echo "$dest_project_json" | jq -r .http_url_to_repo)
      log_info "... sync (force) destination repository ($dest_repo_url)"
      if [[ "$DEST_TOKEN" ]]; then
        # insert login/password in Git https url
        # shellcheck disable=SC2001
        dest_repo_url=$(echo "$dest_repo_url" | sed -e "s|://|://token:${DEST_TOKEN}@|")
      fi
      git ${INSECURE+-c http.sslVerify=false} push --force "$dest_repo_url" --tags "$src_main_branch"
      cd ..
    fi
  fi

  # if project didn't exist: unprotect master branch
  if [[ "$dest_project_status" == 404* ]]
  then
    log_info "... unprotect $src_main_branch branch (allow failure)"
    curl ${INSECURE+-k} -sS -H "${DEST_TOKEN+PRIVATE-TOKEN: $DEST_TOKEN}" -X DELETE "$DEST_GITLAB_API/projects/$dest_project_id/protected_branches/$src_main_branch" > /dev/null
  fi
}

# Synchronizes recursively a GitLab group
# $1: source group full path
# $2: destination parent group ID (number)
# $3: exclude projets/subgroup
# $4: destination group full path
function sync_group() {
  local src_group_full_path=$1
  local dest_parent_id=$2
  local src_group_id=${src_group_full_path//\//%2f}
  local exclude=$3
  local dest_group_full_path=$4
  local dest_group_name=${dest_group_full_path//\//%2f}
  log_info "Synchronizing group \\e[33;1m${src_group_full_path}\\e[0m (parent group ID \\e[33;1m${dest_parent_id:-none (dry run)}\\e[0m)"
  src_group_json=$(curl ${INSECURE+-k} -sSf -H "${SRC_TOKEN+PRIVATE-TOKEN: $SRC_TOKEN}" "$SRC_GITLAB_API/groups/$src_group_id")
  # dump group json (for debug)
  echo "$src_group_json" > "group-$src_group_id.json"

  # 1: sync group itself
  if [[ "$DEST_GITLAB_API" ]]
  then
    dest_visibility=$(adjust_visibility "$(echo "$src_group_json" | jq -r .visibility)")
    dest_group_status=$(curl ${INSECURE+-k} -s -o /dev/null -I -w "%{http_code}" -H "${DEST_TOKEN+PRIVATE-TOKEN: $DEST_TOKEN}" "$DEST_GITLAB_API/groups/$dest_group_name")
    if [[ "$dest_group_status" == 404* ]]
    then
      # dest group does not exist: create
      log_info "... destination group not found: create with visibility \\e[33;1m${dest_visibility}\\e[0m"
      dest_group_json=$(curl ${INSECURE+-k} -sSf -H "${DEST_TOKEN+PRIVATE-TOKEN: $DEST_TOKEN}" -H "Content-Type: application/json" -X POST "$DEST_GITLAB_API/groups" \
        --data "{
          \"path\": $(echo "$src_group_json" | jq .path),
          \"name\": $(echo "$src_group_json" | jq .name),
          \"visibility\": \"$dest_visibility\",
          \"description\": $(echo "$src_group_json" | jq .description),
          \"parent_id\": $dest_parent_id
        }")
    elif [[ "$dest_group_status" == 200* ]]
    then
      # dest group exists: sync
      log_info "... destination group found: synchronize"
      if [[ "${GROUP_DESCRIPTION_DISABLED}" == "true" ]]
      then
        dest_group_json=$(curl ${INSECURE+-k} -sSf -H "${DEST_TOKEN+PRIVATE-TOKEN: $DEST_TOKEN}" -H "Content-Type: application/json" -X PUT "$DEST_GITLAB_API/groups/$dest_group_name" \
          --data "{
            \"name\": $(echo "$src_group_json" | jq .name),
            \"visibility\": \"$dest_visibility\"
          }")
      else
        dest_group_json=$(curl ${INSECURE+-k} -sSf -H "${DEST_TOKEN+PRIVATE-TOKEN: $DEST_TOKEN}" -H "Content-Type: application/json" -X PUT "$DEST_GITLAB_API/groups/$dest_group_name" \
          --data "{
            \"name\": $(echo "$src_group_json" | jq .name),
            \"visibility\": \"$dest_visibility\",
            \"description\": $(echo "$src_group_json" | jq .description)
          }")
      fi
    else
      # another error: abort
      fail "... unexpected error: $dest_group_status"
    fi

    # shellcheck disable=SC2155
    local dest_group_id=$(echo "$dest_group_json" | jq -r .id)

    # set/update avatar url
    src_avatar_url=$(echo "$src_group_json" | jq -r .avatar_url)
    dest_avatar_url=$(echo "$dest_group_json" | jq -r .avatar_url)
    if [[ "$src_avatar_url" != "null" ]] && [[ "$(basename "$src_avatar_url")" != "$(basename "$dest_avatar_url")" ]]
    then
      log_info "... update avatar image ($src_avatar_url)"
      avatar_filename=/tmp/$(basename "$src_avatar_url")
      if curl ${INSECURE+-k} -sSfL --output "$avatar_filename" "$src_avatar_url"
      then
        dest_group_json=$(curl ${INSECURE+-k} -sSf -H "${DEST_TOKEN+PRIVATE-TOKEN: $DEST_TOKEN}" --form "avatar=@$avatar_filename" -X PUT "$DEST_GITLAB_API/groups/$dest_group_id")
      else
        log_warn "... failed downloading avatar image ($src_avatar_url)"
      fi
    fi
  fi

  # 2: sync sub-projects
  # shellcheck disable=SC2155
  local projects_count=$(echo "$src_group_json" | jq '.projects | length')
  for prj_idx in $(seq 0 $((projects_count-1)))
  do
    project_json=$(echo "$src_group_json" | jq -r ".projects[$prj_idx]")
    project_full_path=$(echo "$project_json" | jq -r '.path_with_namespace')
    project_rel_path=${project_full_path#"$SRC_SYNC_PATH/"}
    if [[ ",$exclude," == *,$project_rel_path,* ]]
    then
      log_info "Project \\e[33;1m${project_full_path}\\e[0m matches excludes (\\e[33;1m${exclude}\\e[0m): skip"
    else
      sync_project "$project_json" "$dest_group_id" "$dest_group_full_path"
    fi
  done

  # 3: sync sub-groups
  src_subgroups_json=$(curl ${INSECURE+-k} -sSf -H "${SRC_TOKEN+PRIVATE-TOKEN: $SRC_TOKEN}" "$SRC_GITLAB_API/groups/$src_group_id/subgroups")
  # dump subgroups json (for debug)
  echo "$src_subgroups_json" > "subgroups-$src_group_id.json"
  # shellcheck disable=SC2155
  local subgroups_count=$(echo "$src_subgroups_json" | jq 'length')
  for sub_idx in $(seq 0 $((subgroups_count-1)))
  do
    subgroup_full_path=$(echo "$src_subgroups_json" | jq -r ".[$sub_idx].full_path")
    subgroup_rel_path=${subgroup_full_path#"$SRC_SYNC_PATH/"}
    if [[ ",$exclude," == *,$subgroup_rel_path,* ]]
    then
      log_info "Group \\e[33;1m${subgroup_full_path}\\e[0m matches excludes (\\e[33;1m${exclude}\\e[0m): skip"
    else
      local subgroup_id=${subgroup_full_path//\//%2f}
      mkdir -p "$subgroup_id"
      cd "$subgroup_id"
      dest_subgroup_full_path=${subgroup_full_path/$SRC_SYNC_PATH/$DEST_SYNC_PATH}
      sync_group "$subgroup_full_path" "$dest_group_id" "$exclude" "$dest_subgroup_full_path"
      cd ..
    fi
  done
}

# GitLab source API url defaults to gitlab.com
SRC_GITLAB_API=${SRC_GITLAB_API:-https://gitlab.com/api/v4}
# GitLab destination API url defaults to $CI_API_V4_URL
DEST_GITLAB_API=${DEST_GITLAB_API:-$CI_API_V4_URL}
# GitLab destination token defaults to $GITLAB_TOKEN
DEST_TOKEN=${DEST_TOKEN:-$GITLAB_TOKEN}
# root group path to synchronize
SRC_SYNC_PATH=${SRC_SYNC_PATH:-to-be-continuous}
DEST_SYNC_PATH=${DEST_SYNC_PATH:-to-be-continuous}
MAX_VISIBILITY=${MAX_VISIBILITY:-public}

# parse arguments
POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"
case ${key} in
    -h|--help)
    log_info "Usage: $0"
    log_info "  --src-sync-path {GitLab source root group path to synchronize}"
    log_info "  --dest-sync-path {GitLab destination root group path to synchronize}"
    log_info "  --src-api {GitLab source API url} [--src-token {GitLab source token}]"
    log_info "  --dest-api {GitLab destination API url} [--dest-token {GitLab destination token}]"
    log_info "  [--insecure]"
    log_info "  [--max-visibility {max visibility}]"
    log_info "  [--exclude {coma separated list of project/group path(s) to exclude}]"
    log_info "  [--no-group-description {do not synchronise group description}]"
    log_info "  [--no-project-description {do not synchronise project description}]"
    exit 0
    ;;
    --src-sync-path)
    SRC_SYNC_PATH="$2"
    shift # past argument
    shift # past value
    ;;
    --src-api)
    SRC_GITLAB_API="$2"
    shift # past argument
    shift # past value
    ;;
    --src-token)
    SRC_TOKEN="$2"
    shift # past argument
    shift # past value
    ;;
    --dest-sync-path)
    DEST_SYNC_PATH="$2"
    shift # past argument
    shift # past value
    ;;
    --dest-api)
    DEST_GITLAB_API="$2"
    shift # past argument
    shift # past value
    ;;
    --dest-token)
    DEST_TOKEN="$2"
    shift # past argument
    shift # past value
    ;;
    --max-visibility)
    MAX_VISIBILITY="$2"
    shift # past argument
    shift # past value
    ;;
    --exclude)
    EXCLUDE="$2"
    shift # past argument
    shift # past value
    ;;
    --no-group-description)
    GROUP_DESCRIPTION_DISABLED="true"
    shift # past argument
    shift # past value
    ;;
    --no-project-description)
    PROJECT_DESCRIPTION_DISABLED="true"
    shift # past argument
    shift # past value
    ;;
    --insecure)
    INSECURE="true"
    shift # past argument
    ;;
    *)    # unknown option
    POSITIONAL+=("$1") # save it in an array for later
    shift # past argument
    ;;
esac
done

set -- "${POSITIONAL[@]}" # restore positional parameters

assert_defined "$SRC_GITLAB_API" "GitLab source API url has to be defined ('--src-api' option)"

if [[ "$SRC_GITLAB_API" == "$DEST_GITLAB_API" ]]
then
  fail "Cannot use same GitLab server as source and destination"
fi

log_info "Synchronizing GitLab group"
log_info "- src group   (--src-sync-path)  : \\e[33;1m${SRC_SYNC_PATH}\\e[0m"
log_info "- dest group  (--dest-sync-path) : \\e[33;1m${DEST_SYNC_PATH}\\e[0m"
log_info "- from        (--src-api)        : \\e[33;1m${SRC_GITLAB_API}\\e[0m"
log_info "- to          (--dest-api)       : \\e[33;1m${DEST_GITLAB_API:-none (dry run)}\\e[0m"
log_info "- max visi.   (--max-visibility) : \\e[33;1m${MAX_VISIBILITY}\\e[0m"
log_info "- exclude     (--exclude)        : \\e[33;1m${EXCLUDE:-none}\\e[0m"
log_info "- insecure    (--insecure)       : \\e[33;1m${INSECURE:-false}\\e[0m"
log_info "- disable group desc. sync   (--no-group-description)   : \\e[33;1m${GROUP_DESCRIPTION_DISABLED:-false}\\e[0m"
log_info "- disable project desc. sync (--no-project-description) : \\e[33;1m${PROJECT_DESCRIPTION_DISABLED:-false}\\e[0m"

init_git
# shellcheck disable=SC2046
sync_group "$SRC_SYNC_PATH" $(maybe_create_group $(dirname "$SRC_SYNC_PATH")) "$EXCLUDE" "$DEST_SYNC_PATH"
