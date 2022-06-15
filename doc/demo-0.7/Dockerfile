ARG BUILDER_DIR=/srv/rgb

FROM rust:1.61.0-slim-bullseye as builder

RUN apt-get update \
    && apt-get -y install --no-install-recommends \
        build-essential cmake git pkg-config \
        libpq-dev libssl-dev libzmq3-dev libsqlite3-dev

ARG SRC_DIR=/usr/local/src/rgb
WORKDIR "$SRC_DIR"

ARG BUILDER_DIR
ARG GIT_URL="https://github.com/RGB-WG/rgb-node"
ARG GIT_TAG="v0.7.0-beta.1"
RUN cargo install --git "${GIT_URL}" --tag "${GIT_TAG}" \
        --debug --locked --all-features --root "${BUILDER_DIR}"


FROM debian:bullseye-slim

ARG DATA_DIR=/var/lib/rgb
ARG USER=rgbd

RUN apt-get update \
    && apt-get -y install --no-install-recommends \
       libsqlite3-0 \
       libssl1.1 \
       tini \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN adduser --home "${DATA_DIR}" --shell /bin/bash --disabled-login \
        --gecos "${USER} user" ${USER}

ARG BUILDER_DIR
ARG BIN_DIR=/usr/local/bin
COPY --from=builder --chown=${USER}:${USER} \
     "${BUILDER_DIR}/bin/" "${BIN_DIR}"

WORKDIR "${BIN_DIR}"
USER ${USER}

VOLUME "$DATA_DIR"

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/rgbd", \
            "--bin-dir", "/usr/local/bin", "--data-dir", "/var/lib/rgb"]

CMD ["-vvvv"]
