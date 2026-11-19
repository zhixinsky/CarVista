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
    monkeypatch.setenv("CARVISTA_SEED", "")
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
    local = client.get("/v1/catalog/builtin", headers={"host": "127.0.0.1", "x-forwarded-proto": "https"})
    assert local.json()["items"][0]["preview_url"].startswith("https://carplay.dokor.cn/v1/media/")
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
    original_id = str(uuid.uuid4())
    original = io.BytesIO()
    Image.new("RGB", (40, 20), (10, 40, 80)).save(original, "PNG")
    with_original = client.post(
        "/v1/works",
        data={"id": original_id, "source": "photo", "width": 40, "height": 20, "mode": "深色", "created_at": "2026-11-19T04:00:00Z"},
        files={
            "preview": ("preview.jpg", jpeg_bytes(), "image/jpeg"),
            "original": ("original.png", original.getvalue(), "image/png"),
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert with_original.status_code == 200
    login(client)
    works = client.get("/admin/works")
    assert f"/admin/works/{original_id}/original" in works.text
    downloaded = client.get(f"/admin/works/{original_id}/original")
    assert downloaded.status_code == 200
    assert downloaded.headers["content-type"].startswith("image/png")
    assert "attachment" in downloaded.headers["content-disposition"]
    users = client.get("/admin/users")
    assert "cv-" in users.text
    assert "iPhone17,2" in users.text
    failures = client.get("/admin/diagnostics")
    assert "诊断" in failures.text
    assert "缓存已发生变化" in failures.text
    assert "4064" in failures.text
    assert "2026-11-19 12:00:00" in failures.text
    assert "2026-11-19T04:00:00Z" not in failures.text
    uploaded = client.post("/v1/reports", json={
        "message": "无法写入缓存", "system": "27.2", "appVersion": "0.6.0", "log": "scan",
    }, headers={"Authorization": f"Bearer {token}"})
    assert uploaded.status_code == 200
    assert "internal_name" not in uploaded.text
    listed = client.get("/admin/diagnostics")
    assert "无法写入缓存" in listed.text
    report_id = uploaded.json()["id"]
    detail = client.get(f"/admin/diagnostics/{report_id}")
    assert "scan" in detail.text


def test_empty_catalog(client: TestClient) -> None:
    catalog = client.get("/v1/catalog/buick")
    assert catalog.status_code == 200
    assert catalog.json()["items"] == []


def test_seed_imports_builtin_wallpapers(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    seed = tmp_path / "seed"
    seed.mkdir()
    (seed / "Builtin0.jpg").write_bytes(jpeg_bytes())
    gallery = seed / "BuickGallery"
    gallery.mkdir()
    (gallery / "01.jpeg").write_bytes(jpeg_bytes(width=40, height=10))
    monkeypatch.setenv("CARVISTA_DATA", str(tmp_path / "data"))
    monkeypatch.setenv("CARVISTA_ADMIN_PASSWORD", "secret")
    monkeypatch.setenv("CARVISTA_SESSION_SECRET", "test-secret")
    monkeypatch.setenv("CARVISTA_SEED", str(seed))
    from app.main import create_app
    with TestClient(create_app(), follow_redirects=False) as client:
        builtin = client.get("/v1/catalog/builtin").json()["items"]
        buick = client.get("/v1/catalog/buick").json()["items"]
    assert [item["title"] for item in builtin] == ["壁纸 1"]
    assert [item["title"] for item in buick] == ["别克壁纸 1"]
    with TestClient(create_app(), follow_redirects=False) as client:
        again = client.get("/v1/catalog/builtin").json()["items"]
    assert len(again) == 1


def test_shared_wallpapers_rank_by_likes(client: TestClient) -> None:
    def register() -> dict[str, str]:
        token = client.post("/v1/devices", json={"install_id": str(uuid.uuid4()), "device_machine": "iPhone17,2"}).json()["device_token"]
        return {"Authorization": f"Bearer {token}"}

    first = register()
    second = register()
    share_id = str(uuid.uuid4())
    original = io.BytesIO()
    Image.new("RGB", (40, 16), (20, 30, 40)).save(original, "PNG")
    created = client.post(
        "/v1/shares",
        data={"id": share_id, "title": "海岸共享", "description": "夜景公路", "author": "作者甲", "width": 40, "height": 16},
        files={
            "preview": ("preview.jpg", jpeg_bytes(), "image/jpeg"),
            "original": ("original.png", original.getvalue(), "image/png"),
        },
        headers=first,
    )
    assert created.status_code == 200
    assert "internal_name" not in created.text
    listed = client.get("/v1/shares", headers=first).json()["items"]
    assert listed[0]["title"] == "海岸共享"
    assert listed[0]["description"] == "夜景公路"
    assert listed[0]["author"] == "作者甲"
    assert listed[0]["likes"] == 0
    metadata_url = f"/v1/shares/{share_id}/metadata"
    assert client.get(metadata_url, headers=first).json() == {
        "title": "海岸共享", "description": "夜景公路", "author": "作者甲"
    }
    assert client.get(metadata_url, headers=second).status_code == 403
    assert client.patch(metadata_url, data={"title": "越权修改"}, headers=second).status_code == 403
    assert client.patch(metadata_url, data={"title": "  "}, headers=first).status_code == 400
    updated = client.patch(metadata_url, data={"title": "修改后的名称", "description": "修改后的介绍", "author": "作者乙"}, headers=first)
    assert updated.status_code == 200
    assert client.get(metadata_url, headers=first).json() == {
        "title": "修改后的名称", "description": "修改后的介绍", "author": "作者乙"
    }
    client.patch(metadata_url, data={"title": "海岸共享", "description": "夜景公路"}, headers=first)
    liked = client.post(f"/v1/shares/{share_id}/like", headers=second)
    assert liked.json() == {"likes": 1, "liked": True}
    removed = client.post(f"/v1/shares/{share_id}/like", headers=second)
    assert removed.json()["likes"] == 0
    client.post(f"/v1/shares/{share_id}/like", headers=first)
    assert client.get("/v1/shares").json()["items"][0]["likes"] == 1
    assert "cv-" not in client.get("/v1/shares").text
    login(client)
    assert "海岸共享" in client.get("/admin/shares").text
    page = client.get("/admin/shares")
    csrf = page.text.split('name="csrf" value="', 1)[1].split('"', 1)[0]
    url = f"/admin/shares/{share_id}/likes"
    assert client.post(url, data={"csrf": "invalid", "likes": 20}).status_code == 403
    assert client.post(url, data={"csrf": csrf, "likes": -1}).status_code == 400
    assert client.post(url, data={"csrf": csrf, "likes": 20}).status_code == 303
    assert client.get("/v1/shares", headers=first).json()["items"][0]["likes"] == 20
    assert client.get("/v1/shares", headers=first).json()["items"][0]["liked"] is True
    assert client.post(f"/v1/shares/{share_id}/like", headers=second).json()["likes"] == 21
    assert client.post(f"/v1/shares/{share_id}/like", headers=second).json()["likes"] == 20
    assert client.post(url, data={"csrf": csrf, "likes": 0}).status_code == 303
    assert client.post(f"/v1/shares/{share_id}/like", headers=first).json()["likes"] == 0
    title_url = f"/admin/shares/{share_id}/title"
    assert client.post(title_url, data={"csrf": "invalid", "title": "新名称"}).status_code == 403
    assert client.post(title_url, data={"csrf": csrf, "title": " "}).status_code == 400
    assert client.post(title_url, data={"csrf": csrf, "title": "后台新名称"}).status_code == 303
    assert client.get("/v1/shares").json()["items"][0]["title"] == "后台新名称"
    assert client.get(metadata_url, headers=first).json()["title"] == "后台新名称"

