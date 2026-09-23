# Builds the three Gnoracle tools into one small image.
#   docker build -t gnoracle .
#   docker run --rm -v $PWD/agent.toml:/etc/gnoracle/agent.toml -e GNORACLE_MNEMONIC="..." gnoracle gnoracle-agent -config /etc/gnoracle/agent.toml
FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/ ./cmd/...

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/gnoracle /out/gnoracle-agent /out/gnoracle-bot /usr/local/bin/
VOLUME /var/lib/gnoracle
ENTRYPOINT ["gnoracle-agent"]
CMD ["-config", "/etc/gnoracle/agent.toml"]
