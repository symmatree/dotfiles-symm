FROM golang:1.26.5 AS build
COPY installer /src
WORKDIR /src
RUN CGO_ENABLED=0 go build -o /out/cubie_a7s .

FROM scratch
COPY --from=build /out/cubie_a7s /installers/cubie_a7s
COPY artifacts /artifacts
COPY profiles /profiles
