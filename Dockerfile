FROM julia:1.10-alpine

RUN apk update
RUN apk add gnu-libiconv

RUN adduser -D wbdav

USER wbdav
WORKDIR /home/wbdav

COPY --chown=wbdav:wbdav Project.toml .
COPY --chown=wbdav:wbdav src  ./src
COPY --chown=wbdav:wbdav deps ./deps

RUN julia --project="@." -e "import Pkg; Pkg.build()"

EXPOSE 8008/tcp

CMD julia --project="@." -e "import WbDav; WbDav.serve()"
