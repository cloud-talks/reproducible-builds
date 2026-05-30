FROM golang:1.22@sha256:1cf6c45ba39db9fd6db16922041d074a63c935556a05c5ccb62d181034df7f02 AS builder
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-buildid= -s -w" -o /app .

FROM cgr.dev/chainguard/static@sha256:67a1b00e0134e2b3a614c7198a26f7deed9d11b7acad4d52c79c0cfd47a2eae7
COPY --from=builder /app /server
ENTRYPOINT ["/server"]
