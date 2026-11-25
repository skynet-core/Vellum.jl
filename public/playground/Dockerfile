FROM julia:1.10.13-bookworm AS runtime
LABEL org.opencontainers.image.source="https://github.com/skynet-core/Vellum.jl" \
      org.opencontainers.image.licenses="Apache-2.0"
ENV JULIA_DEPOT_PATH=/opt/depot: JULIA_PROJECT=/opt/vellum JULIA_CPU_TARGET=generic JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1
WORKDIR /opt/vellum
COPY Project.toml Manifest.toml LICENSE NOTICE ./
COPY src/ src/
COPY ext/ ext/
COPY public/playground/Project.toml public/playground/Manifest.toml /opt/playground/
RUN ["julia","--startup-file=no","--project=/opt/playground","-e","using Pkg; Pkg.instantiate()"]
ENV JULIA_LOAD_PATH=@:/opt/playground:/opt/vellum:@stdlib
RUN ["julia","--startup-file=no","-e","using Pkg; Pkg.instantiate(); using Vellum; mktempdir() do dir; f=drawing(e->rectangle!(e,0,0,4,4;fill=Solid(1,0,0));size=(4,4)); savehtml(joinpath(dir,\"warm.html\"),f;target=:webgl2); end"]
COPY tutorials/ tutorials/
COPY docs/lessons.jl docs/lessons.jl
COPY test/fixtures/ test/fixtures/
COPY public/playground/worker.jl public/playground/render.jl /opt/playground/
USER 65532:65532
CMD ["julia","--startup-file=no","/opt/playground/worker.jl"]

FROM docker:28-cli AS engine
FROM runtime AS service
COPY --from=engine /usr/local/bin/docker /usr/local/bin/docker
USER root
COPY public/playground/build_lessons.jl public/playground/catalog.jl /opt/playground/
RUN ["julia","--startup-file=no","/opt/playground/build_lessons.jl"]
COPY public/playground/page.jl public/playground/server.jl public/playground/sketch.jl /opt/playground/
USER 65532:65532
EXPOSE 8080
CMD ["julia","--startup-file=no","/opt/playground/server.jl"]
