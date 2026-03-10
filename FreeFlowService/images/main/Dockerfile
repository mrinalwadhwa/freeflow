FROM ghcr.io/build-trust/autonomy-python-dev AS dev
USER root
COPY requirements.txt ./
RUN pip install -r requirements.txt
RUN apk update && apk add nodejs-22 pnpm
COPY auth/package.json auth/pnpm-lock.yaml auth/
RUN cd auth && pnpm install --frozen-lockfile --prod

FROM ghcr.io/build-trust/autonomy-python
COPY --from=dev /app/venv venv
COPY --from=dev /usr/bin/node /usr/bin/node
COPY --from=dev /usr/lib/libuv.so* /usr/lib/
COPY --from=dev /usr/lib/libcares.so* /usr/lib/
COPY --from=dev /usr/lib/libbrotlicommon.so* /usr/lib/
COPY --from=dev /usr/lib/libbrotlidec.so* /usr/lib/
COPY --from=dev /usr/lib/libbrotlienc.so* /usr/lib/
COPY --from=dev /usr/lib/libnghttp2.so* /usr/lib/
COPY --from=dev /usr/lib/libicui18n.so* /usr/lib/
COPY --from=dev /usr/lib/libicuuc.so* /usr/lib/
COPY --from=dev /usr/lib/libicudata.so* /usr/lib/
COPY --from=dev /app/auth/node_modules auth/node_modules
COPY . .
ENTRYPOINT ["python", "main.py"]
