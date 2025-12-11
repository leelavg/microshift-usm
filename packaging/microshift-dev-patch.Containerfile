FROM localhost/microshift-okd:latest

# Copy OKD release image manifest (fixes OCP->OKD image substitution)
COPY release-x86_64.json /usr/share/microshift/release/release-x86_64.json

# Copy fixed microshift binary with LoadBalancer controller fix
COPY microshift /usr/bin/microshift

# Copy microshift-etcd binary with self-healing config regeneration
COPY microshift-etcd /usr/bin/microshift-etcd
