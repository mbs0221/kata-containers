#!/usr/bin/env bash
#
# Copyright (c) 2023 Intel
#
# SPDX-License-Identifier: Apache-2.0

set -o errexit
set -o nounset
set -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly agent_builder="${script_dir}/build-static-agent.sh"

source "${script_dir}/../../scripts/lib.sh"

container_image="${AGENT_CONTAINER_BUILDER:-$(get_agent_image_name)}"
[ "${CROSS_BUILD}" == "true" ] && container_image="${container_image}-cross-build"
common_git_dir="$(git -C "${repo_root_dir}" rev-parse --path-format=absolute --git-common-dir)"
git_mount_args=()
case "${common_git_dir}" in
	"${repo_root_dir}"/*) ;;
	*) git_mount_args=(-v "${common_git_dir}:${common_git_dir}:ro") ;;
esac
build_network_args=()
if [ "${KATA_BUILD_NETWORK:-}" = "host" ]; then
	build_network_args=(--network=host --env HTTP_PROXY --env HTTPS_PROXY --env ALL_PROXY --env NO_PROXY --env CARGO_NET_GIT_FETCH_WITH_CLI=true)
fi
LIBSECCOMP_VERSION="${LIBSECCOMP_VERSION:-$(get_from_kata_deps ".externals.libseccomp.version")}"
LIBSECCOMP_URL="${LIBSECCOMP_URL:-$(get_from_kata_deps ".externals.libseccomp.url")}"
GPERF_VERSION="${GPERF_VERSION:-$(get_from_kata_deps ".externals.gperf.version")}"
GPERF_URL="${GPERF_URL:-$(get_from_kata_deps ".externals.gperf.url")}"

if [ -z "${AGENT_CONTAINER_BUILDER:-}" ] || ! docker image inspect "${container_image}" >/dev/null 2>&1; then
docker pull ${container_image} || \
	(docker $BUILDX build $PLATFORM \
	    	--build-arg RUST_TOOLCHAIN="$(get_from_kata_deps ".languages.rust.meta.newest-version")" \
		-t "${container_image}" "${script_dir}" && \
	 # No-op unless PUSH_TO_REGISTRY is exported as "yes"
	 push_to_registry "${container_image}")
fi

docker run --rm -i -v "${repo_root_dir}:${repo_root_dir}" "${git_mount_args[@]}" "${build_network_args[@]}" \
	--env DESTDIR=${DESTDIR} \
	--env AGENT_POLICY=${AGENT_POLICY:-no} \
	--env PULL_TYPE=${PULL_TYPE:-default} \
	--env LIBSECCOMP_VERSION=${LIBSECCOMP_VERSION} \
	--env LIBSECCOMP_URL=${LIBSECCOMP_URL} \
	--env GPERF_VERSION=${GPERF_VERSION} \
	--env GPERF_URL=${GPERF_URL} \
	-w "${repo_root_dir}" \
	--user "$(id -u)":"$(id -g)" \
	"${container_image}" \
	bash -c "${agent_builder}"
