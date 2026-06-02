FROM docker.io/library/debian:trixie-slim AS engine

RUN dpkg --add-architecture i386
RUN apt update && apt upgrade -y && apt -y --no-install-recommends install aptitude
RUN aptitude -y --without-recommends install git ca-certificates build-essential gcc-multilib g++-multilib libbsd-dev:i386 libsdl2-dev:i386 libfreetype-dev:i386 libopus-dev:i386 libbz2-dev:i386 libvorbis-dev:i386 libopusfile-dev:i386 libogg-dev:i386

ENV PKG_CONFIG_PATH=/usr/lib/i386-linux-gnu/pkgconfig

WORKDIR /xash

RUN for attempt in 1 2 3; do \
        git -c http.version=HTTP/1.1 clone --depth 1 --branch merged --single-branch https://github.com/yohimik/xash3d-fwgs . \
        && git submodule update --init --recursive --depth 1 \
        && break; \
        echo "xash3d-fwgs clone attempt ${attempt} failed" >&2; \
        rm -rf .git ./*; \
        if [ "$attempt" -eq 3 ]; then exit 1; fi; \
        sleep 5; \
    done

RUN ./waf configure -T release -d --enable-openmp && ./waf build

FROM docker.io/library/golang:1.25.1 AS go

WORKDIR /go
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc-multilib \
    g++-multilib \
    libc6-dev-i386 \
    && apt-get clean
COPY go.mod go.mod
COPY go.sum go.sum
RUN go mod download
RUN mkdir -p ../github.com/yohimik/goxash3d-fwgs
RUN cp -r $(go list -m -f '{{.Dir}}' github.com/yohimik/goxash3d-fwgs)/* ../github.com/yohimik/goxash3d-fwgs
RUN echo 'replace github.com/yohimik/goxash3d-fwgs => ../github.com/yohimik/goxash3d-fwgs' >> go.mod

COPY src/server src/server
COPY --from=engine /xash/build/engine/libxash.a ../github.com/yohimik/goxash3d-fwgs/pkg/libxash.a
COPY --from=engine /xash/build/public/libbuild_vcs.a ../github.com/yohimik/goxash3d-fwgs/pkg/libbuild_vcs.a
COPY --from=engine /xash/build/public/libpublic.a ../github.com/yohimik/goxash3d-fwgs/pkg/libpublic.a
COPY --from=engine /xash/build/3rdparty/libbacktrace/libbacktrace.a ../github.com/yohimik/goxash3d-fwgs/pkg/libbacktrace.a
COPY --from=engine /xash/build/3rdparty/library_suffix/liblibrary_suffix.a ../github.com/yohimik/goxash3d-fwgs/pkg/liblibrary_suffix.a

ENV GOARCH=386
ENV CGO_ENABLED=1
ENV CC="gcc -m32 -D__i386__"
ENV CGO_CFLAGS="-fopenmp -m32 -fno-ipa-cp"
ENV CGO_LDFLAGS="-fopenmp -m32"
RUN go build -o ./xash ./src/server


FROM docker.io/library/debian:trixie-slim AS hlds

ARG hlds_build=8308
ARG hlds_url="https://github.com/DevilBoy-eXe/hlds/releases/download/$hlds_build/hlds_build_$hlds_build.zip"

RUN groupadd -r xash && useradd -r -g xash -m -d /opt/xash xash
RUN usermod -a -G games xash

RUN apt-get -y update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    unzip \
    && apt-get -y clean

USER xash
WORKDIR /opt/xash
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN mkdir -p /opt/xash/xashds

RUN curl -sLJO "$hlds_url" \
    && unzip "hlds_build_$hlds_build.zip" -d "/opt/xash/hlds_build_$hlds_build" \
    && cp -R "hlds_build_$hlds_build/hlds"/* xashds/ \
    && rm -rf "hlds_build_$hlds_build" "hlds_build_$hlds_build.zip"

# Fix warnings:
# couldn't exec listip.cfg
# couldn't exec banned.cfg
RUN touch /opt/xash/xashds/valve/listip.cfg
RUN touch /opt/xash/xashds/valve/banned.cfg

WORKDIR /opt/xash/xashds

# Copy default config
COPY configs/valve valve
COPY configs/cstrike cstrike

FROM --platform=linux/amd64 docker.io/library/node:22-alpine AS client

WORKDIR /client

COPY package.json package.json
COPY wasm/package.json wasm/package.json
RUN npm install
RUN cd wasm && npm install
COPY vite.config.ts vite.config.ts
COPY tsconfig.json tsconfig.json
COPY src/client src/client
COPY wasm wasm

RUN npm run build


FROM docker.io/library/debian:trixie-slim AS final

ENV XASH3D_BASEDIR=/xashds

RUN dpkg --add-architecture i386
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgcc-s1:i386 \
    libstdc++6:i386 \
    libgomp1:i386 \
    ca-certificates \
    openssl \
    && apt-get clean

RUN groupadd xashds && useradd -m -g xashds xashds
USER xashds
WORKDIR /xashds
ENV LD_LIBRARY_PATH=/xashds

COPY --from=hlds /opt/xash/xashds .
COPY --from=go /go/xash ./xash
COPY --from=client /client/src/client/dist ./public
COPY --from=client /client/wasm/node_modules/cs16-client/dist/cstrike/ ./public/cstrike
COPY --from=client /client/wasm/node_modules/xash3d-fwgs/dist/filesystem_stdio.wasm ./public/filesystem_stdio.wasm
COPY --from=engine /xash/build/filesystem/filesystem_stdio.so ./filesystem_stdio.so
COPY --from=engine "/usr/lib/i386-linux-gnu/libstdc++.so.6" "./libstdc++.so.6"
COPY --from=engine "/usr/lib/i386-linux-gnu/libgcc_s.so.1" "./libgcc_s.so.1"
EXPOSE 27015/udp

# Engine configuration
ENV GAME_DIR="cstrike"
ENV ENGINE_ARGS="-windowed,-game,cstrike"
ENV ENGINE_CONSOLE="_vgui_menus 0"

# Library paths
ENV CLIENT_WASM_PATH="cstrike/cl_dlls/client_emscripten_wasm32.wasm"
ENV SERVER_WASM_PATH="cstrike/dlls/cs_emscripten_wasm32.wasm"
ENV MENU_WASM_PATH="cstrike/cl_dlls/menu_emscripten_wasm32.wasm"
ENV EXTRAS_PATH="cstrike/extras.pk3"
ENV FILESYSTEM_WASM_PATH="filesystem_stdio.wasm"
ENV DYNAMIC_LIBRARIES="dlls/cs_emscripten_wasm32.wasm,/rodir/filesystem_stdio.wasm"
ENV FILES_MAP="dlls/cs_emscripten_wasm32.wasm:cstrike/dlls/cs_emscripten_wasm32.wasm,/rodir/filesystem_stdio.wasm:filesystem_stdio.wasm"

# Start server
ENTRYPOINT ["./xash", "+ip", "0.0.0.0", "-port", "27015", "-game", "cstrike"]

# Default start parameters
CMD ["+map de_dust2", "+maxplayers", "16"]
