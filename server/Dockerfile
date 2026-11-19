FROM python:3.12-slim

WORKDIR /app
COPY server/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server/app ./app
COPY ios/BuiltinWallpapers /seed/wallpapers

ENV CARVISTA_DATA=/data
ENV CARVISTA_SEED=/seed/wallpapers
EXPOSE 8787
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8787"]
