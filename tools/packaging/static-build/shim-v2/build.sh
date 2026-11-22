#!/usr/bin/env bash
#
# Copyright (c) 2021 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0

set -o errexit
set -o nounset
set -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${script_dir}/../../scripts/lib.sh"

VMM_CONFIGS="qemu fc"

GO_VERSION=${GO_VERSION}
RUST_VERSION=${RUST_VERSION}
CC=""

DESTDIR=${DESTDIR:-${PWD}}
PREFIX=${PREFIX:-/opt/kata}
container_image="${SHIM_V2_CONTAINER_BUILDER:-$(get_shim_v2_image_name)}"
common_git_dir="$(git -C "${repo_root_dir}" rev-parse --path-format=absolute --git-common-dir)"
git_mount_args=()
case "${common_git_dir}" in
	"${repo_root_dir}"/*) ;;
	*) git_mount_args=(-v "${common_git_dir}:${common_git_dir}:ro") ;;
esac
build_network_args=()
if [ "${KATA_BUILD_NETWORK:-}" = "host" ]; then
	build_network_args=(--network=host --env HTTP_PROXY --env HTTPS_PROXY --env ALL_PROXY --env NO_PROXY)
fi

EXTRA_OPTS="${EXTRA_OPTS:-""}"

[ "${CROSS_BUILD}" == "true" ] && container_image_bk="${container_image}" && container_image="${container_image}-cross-build"
if [ "${MEASURED_ROOTFS}" == "yes" ]; then
	info "Enable rootfs measurement config"

	root_hash_file="${repo_root_dir}/tools/packaging/kata-deploy/local-build/build/root_hash.txt"

	[ -f "$root_hash_file" ] || \
		die "Root hash file for measured rootfs not found at ${root_hash_file}"

	root_hash=$(sed -e 's/Root hash:\s*//g;t;d' "${root_hash_file}")
	root_measure_config="rootfs_verity.scheme=dm-verity rootfs_verity.hash=${root_hash}"
	EXTRA_OPTS+=" ROOTMEASURECONFIG=\"${root_measure_config}\""
fi

if [ -z "${SHIM_V2_CONTAINER_BUILDER:-}" ] || ! docker image inspect "${container_image}" >/dev/null 2>&1; then
docker pull ${container_image} || \
	(docker ${BUILDX} build ${PLATFORM}  \
		--build-arg GO_VERSION="${GO_VERSION}" \
		--build-arg RUST_VERSION="${RUST_VERSION}" \
		-t "${container_image}" \
		"${script_dir}" && \
	 push_to_registry "${container_image}")
fi

arch=${ARCH:-$(uname -m)}
GCC_ARCH=${arch}
if [ ${arch} = "ppc64le" ]; then
	GCC_ARCH="powerpc64le"
	arch="ppc64"
fi

#Build rust project using cross build musl image to speed up
[[ "${CROSS_BUILD}" == "true" && ${ARCH} != "s390x" ]] && container_image="messense/rust-musl-cross:${GCC_ARCH}-musl" && CC=${GCC_ARCH}-unknown-linux-musl-gcc

docker run --rm -i -v "${repo_root_dir}:${repo_root_dir}" "${git_mount_args[@]}" "${build_network_args[@]}" \
	--env CROSS_BUILD=${CROSS_BUILD} \
	--env ARCH=${ARCH} \
	--env CC="${CC}" \
	-w "${repo_root_dir}/src/runtime-rs" \
	--user "$(id -u)":"$(id -g)" \
	"${container_image}" \
	bash -c "make clean-generated-files && make PREFIX=${PREFIX} QEMUCMD=qemu-system-${arch}"

docker run --rm -i -v "${repo_root_dir}:${repo_root_dir}" "${git_mount_args[@]}" "${build_network_args[@]}" \
	--env CROSS_BUILD=${CROSS_BUILD} \
        --env ARCH=${ARCH} \
        --env CC="${CC}" \
	-w "${repo_root_dir}/src/runtime-rs" \
	--user "$(id -u)":"$(id -g)" \
	"${container_image}" \
	bash -c "make PREFIX="${PREFIX}" DESTDIR="${DESTDIR}" install"

[ "${CROSS_BUILD}" == "true" ] && container_image="${container_image_bk}-cross-build"

docker run --rm -i -v "${repo_root_dir}:${repo_root_dir}" "${git_mount_args[@]}" "${build_network_args[@]}" \
	-w "${repo_root_dir}/src/runtime" \
	--user "$(id -u)":"$(id -g)" \
	"${container_image}" \
	bash -c "make clean-generated-files && make PREFIX=${PREFIX} QEMUCMD=qemu-system-${arch} ${EXTRA_OPTS}"

docker run --rm -i -v "${repo_root_dir}:${repo_root_dir}" "${git_mount_args[@]}" "${build_network_args[@]}" \
	-w "${repo_root_dir}/src/runtime" \
	--user "$(id -u)":"$(id -g)" \
	"${container_image}" \
	bash -c "make PREFIX="${PREFIX}" DESTDIR="${DESTDIR}" ${EXTRA_OPTS} install"

for vmm in ${VMM_CONFIGS}; do
	config_file="${DESTDIR}/${PREFIX}/share/defaults/kata-containers/configuration-${vmm}.toml"
	if [ -f ${config_file} ]; then
		if [ ${ARCH} == "ppc64le" ]; then
 			sed -i -e '/^image =/d' ${config_file}
 			sed -i 's/^# \(initrd =.*\)/\1/g' ${config_file}
 		else
 			sed -i -e '/^initrd =/d' ${config_file}
 		fi
	fi
done

pushd "${DESTDIR}/${PREFIX}/share/defaults/kata-containers"
	ln -sf "configuration-qemu.toml" configuration.toml
popd
