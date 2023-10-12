ARG BCC_VERSION=ec49363e2e9daec026ee6cae4c5fc316f8fab0ff

FROM ghcr.io/vietanhduong/bcc:${BCC_VERSION} as bcc

FROM debian:bookworm-20230919 

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y debootstrap curl

WORKDIR /scripts
COPY build-sysroot.sh build-sysroot.sh

RUN mkdir -p /bcc/usr/include/bcc \
  /bcc/usr/lib/x86_64-linux-gnu

COPY --from=bcc /usr/include/bcc /bcc/usr/include/bcc
COPY --from=bcc /usr/lib/x86_64-linux-gnu/libbcc* /bcc/usr/lib/x86_64-linux-gnu

ENTRYPOINT [ "/scripts/build-sysroot.sh" ]

VOLUME [ "/builds" ]
