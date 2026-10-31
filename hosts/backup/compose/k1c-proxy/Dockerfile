FROM python:3.13-alpine
RUN pip install --no-cache-dir aiohttp==3.12.15
COPY proxy.py /app/proxy.py
CMD ["python", "/app/proxy.py"]
