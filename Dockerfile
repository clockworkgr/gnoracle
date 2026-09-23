# Builds the three Gnoracle tools into one small image.
#   docker build -t gnoracle .
#   docker run --rm -v $PWD/agent.toml:/etc/gnoracle/agent.toml -e GNORACLE_MNEMONIC="..." gnoracle gnoracle-agent -config /etc/gnoracle/agent.toml
FROM golang:1.25.9 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/ ./cmd/... \
 && mkdir -p /out/state

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/gnoracle /out/gnoracle-agent /out/gnoracle-bot /usr/local/bin/
# the state, journal and key directory the configs point at, owned by the
# non-root user the image runs as (uid 65532); bind mounts must match
COPY --from=build --chown=65532:65532 /out/state /var/lib/gnoracle
VOLUME /var/lib/gnoracle
ENTRYPOINT ["gnoracle-agent"]
CMD ["-config", "/etc/gnoracle/agent.toml"]
