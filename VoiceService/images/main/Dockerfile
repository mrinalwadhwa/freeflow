FROM ghcr.io/build-trust/autonomy-python-dev AS dev
COPY requirements.txt ./
RUN pip install -r requirements.txt

FROM ghcr.io/build-trust/autonomy-python
COPY --from=dev /app/venv venv
COPY . .
ENTRYPOINT ["python", "main.py"]
