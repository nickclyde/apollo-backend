# syntax=docker/dockerfile:1.6

FROM golang:1.24-alpine AS builder
RUN apk add --no-cache git ca-certificates tzdata
WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w" \
    -o /out/apollo \
    ./cmd/apollo

FROM alpine:3.19
RUN apk add --no-cache ca-certificates curl tzdata wget && \
    addgroup -S apollo && adduser -S apollo -G apollo

COPY --from=builder /out/apollo /usr/local/bin/apollo

USER apollo
EXPOSE 4000 6060 8080

ENTRYPOINT ["/usr/local/bin/apollo"]
