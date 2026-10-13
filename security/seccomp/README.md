# Primary-host bubblewrap seccomp profile

This opt-in OCI profile is derived from containerd's unprivileged default
syscall allowlist, licensed under Apache-2.0. Copyright The containerd Authors.
Source: https://github.com/containerd/containerd/blob/main/contrib/seccomp/seccomp_default.go
Reviewed source blob: `eda02236a42405442ad68e350cd14e7353d38b7a`.
The Apache license is retained in `LICENSE` next to this file.

Changes for this workload:

- Allow clone with both a new user namespace and a new mount namespace. Normal
  clones without namespace flags remain allowed; clone3 returns ENOSYS so libc
  falls back to the argument-filterable clone syscall.
- Allow unshare and setns only for user namespaces, for bubblewrap's nested
  user namespace setup.
- Allow mount, umount2, pivot_root, chroot, and sethostname. Kernel capability
  checks still apply: these operations require the new user namespace's own
  privileges and do not grant capabilities in the pod's original namespace.
- Preserve a default-deny policy, exclude newer syscalls requiring recent
  libseccomp releases, and do not enable privileged administration syscalls
  such as bpf, kernel module loading, reboot, or perf_event_open.
- Keep socket address-family restrictions, including denying AF_ALG and
  AF_VSOCK. The profile uses the runtime's native architecture (amd64 or arm64).

Install the JSON file under each node's kubelet seccomp root before enabling
`primaryHost.bubblewrap.enabled`. Kubelet cannot load this profile from an image
or a ConfigMap. CI copies it to the disposable kind node before the opt-in test.
This profile allows namespace setup; bubblewrap's own arguments define the
actual filesystem and network sandbox. It is not a substitute for node kernel,
AppArmor/SELinux, or runtime policy that permits unprivileged user namespaces.
