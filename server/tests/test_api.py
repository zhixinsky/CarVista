# SPDX-License-Identifier: GPL-3.0-or-later
import io
import os
import uuid
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from PIL import Image


@pytest.fixture()
def client(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("CARVISTA_DATA", str(tmp_path))
    monkeypatch.setenv("CARVISTA_ADMIN_PASSWORD", "secret")
    monkeypatch.setenv("CARVISTA_SESSION_SECRET", "test-secret")
    monkeypatch.setenv("CARVISTA_ADMIN_USER", "admin")
    from app.main import create_app
    with TestClient(create_app(), follow_redirects=False) as test_client:
        yield test_client


def jpeg_bytes(width: int = 32, height: int = 16) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (width, height), (20, 80, 90)).save(buffer, "JPEG")
    return buffer.getvalue()


def login(client: TestClient) -> None:
    page = client.get("/admin/login")
    assert page.status_code == 200
    token = page.text.split('name="csrf" value="', 1)[1].split('"', 1)[0]
    response = client.post("/admin/login", data={"username": "admin", "password": "secret", "csrf": token}, follow_redirects=False)
    assert response.status_code == 303
    assert response.headers["location"] == "/admin"


def test_catalog_hides_unpublished_and_names(client: TestClient) -> None:
    assert client.get("/admin/assets").status_code == 303
    login(client)
    page = client.get("/admin/assets?collection=builtin")
    token = page.text.split('name="csrf" value="', 1)[1].split('"', 1)[0]
    created = client.post(
        "/admin/assets",
        data={"csrf": token, "collection": "builtin", "title": "海岸", "published": "on"},
        files={"file": ("coast.jpg", jpeg_bytes(), "image/jpeg")},
        follow_redirects=False,
    )
    assert created.status_code == 303
    catalog = client.get("/v1/catalog/builtin")
    assert catalog.status_code == 200
    body = catalog.json()
    assert body["items"][0]["title"] == "海岸"
    assert body["items"][0]["preview_url"].endswith("/preview")
    assert "internal_name" not in catalog.text
    media = client.get(body["items"][0]["preview_url"].replace("http://testserver", ""))
    assert media.status_code == 200
    assert media.headers["content-type"].startswith("image/jpeg")
    cached = client.get("/v1/catalog/builtin", headers={"If-None-Match": catalog.headers["etag"]})
    assert cached.status_code == 304


def test_device_token_does_not_reveal_internal_name(client: TestClient) -> None:
    install_id = str(uuid.uuid4())
    first = client.post("/v1/devices", json={"install_id": install_id, "app_version": "0.5.0", "ios_version": "27.2", "device_model": "iPhone", "device_machine": "iPhone17,2"})
    assert first.status_code == 200
    assert "device_token" in first.json()
    assert "internal_name" not in first.json()
    assert "cv-" not in first.text
    second = client.post("/v1/devices", json={"install_id": install_id, "device_machine": "iPhone17,2"})
    assert second.json()["device_token"] != first.json()["device_token"]
    denied = client.post("/v1/events", json={"events": []}, headers={"Authorization": f"Bearer {first.json()['device_token']}"})
    assert denied.status_code == 401
    token = second.json()["device_token"]
    event_id = str(uuid.uuid4())
    accepted = client.post("/v1/events", json={"events": [{
        "id": event_id,
        "type": "apply_result",
        "at": "2026-11-19T04:00:00Z",
        "ok": False,
        "app_version": "0.5.0",
        "ios_version": "27.2",
        "payload": {"message": "缓存已发生变化", "target_width": 4064, "target_height": 1112, "mode": "深色"},
    }]}, headers={"Authorization": f"Bearer {token}"})
    assert accepted.json()["accepted"] == [event_id]
    work_id = str(uuid.uuid4())
    uploaded = client.post(
        "/v1/works",
        data={"id": work_id, "source": "builtin", "width": 4064, "height": 1112, "mode": "深色", "created_at": "2026-11-19T04:00:00Z"},
        files={"preview": ("preview.jpg", jpeg_bytes(), "image/jpeg")},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert uploaded.status_code == 200
    again = client.post(
        "/v1/works",
        data={"id": work_id, "source": "builtin", "width": 1, "height": 1, "mode": "深色", "created_at": "2026-11-19T04:00:00Z"},
        files={"preview": ("preview.jpg", jpeg_bytes(), "image/jpeg")},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert again.json()["duplicate"] is True
    login(client)
    users = client.get("/admin/users")
    assert "cv-" in users.text
    assert "iPhone17,2" in users.text
    failures = client.get("/admin/failures")
    assert "缓存已发生变化" in failures.text
    assert "4064" in failures.text


def test_empty_catalog(client: TestClient) -> None:
    catalog = client.get("/v1/catalog/buick")
    assert catalog.status_code == 200
    assert catalog.json()["items"] == []
