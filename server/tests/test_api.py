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
        shares = client.get("/v1/shares").json()["items"]
    assert builtin == []
    assert [item["title"] for item in buick] == ["别克壁纸 1"]
    assert [item["title"] for item in shares] == ["壁纸 1"]
    with TestClient(create_app(), follow_redirects=False) as client:
        again = client.get("/v1/shares").json()["items"]
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
    edit_url = f"/admin/shares/{share_id}/edit"
    assert client.post(edit_url, data={"csrf": "invalid", "title": "修改", "likes": 8}).status_code == 403
    assert client.post(edit_url, data={"csrf": csrf, "title": "修改", "likes": -1}).status_code == 400
    assert client.post(edit_url, data={"csrf": csrf, "title": "统一编辑", "description": "后台描述", "likes": 8}).status_code == 303
    item = client.get("/v1/shares").json()["items"][0]
    assert (item["title"], item["description"], item["likes"]) == ("统一编辑", "后台描述", 8)
    publish_url = f"/admin/shares/{share_id}/publish"
    assert client.post(publish_url, data={"csrf": "invalid"}).status_code == 403
    assert client.post(publish_url, data={"csrf": csrf}).status_code == 303
    assert client.get("/v1/shares").json()["items"] == []
    assert client.get(f"/v1/shares/{share_id}/original").status_code == 404
    assert client.post(f"/v1/shares/{share_id}/like", headers=second).status_code == 404
    download = client.get(f"/admin/shares/{share_id}/media/original?download=true")
    assert download.status_code == 200
    assert "attachment" in download.headers["content-disposition"]
    assert client.get(f"/admin/shares/{share_id}/media/preview").status_code == 200
    assert client.post(publish_url, data={"csrf": csrf, "published": "on"}).status_code == 303
    assert client.get("/v1/shares").json()["items"][0]["likes"] == 8



def test_dynamic_gallery_categories(client: TestClient) -> None:
    initial = client.get('/v1/gallery/categories').json()['items']
    assert [item['title'] for item in initial] == [
        '默认壁纸', '精选壁纸', '必应壁纸', '主题搜图', '别克车机壁纸', '测试'
    ]
    assert initial[-1]['hidden'] == 1
    assert client.post('/admin/categories', data={'title': '新分类', 'csrf': 'bad'}).status_code == 303
    login(client)
    page = client.get('/admin/categories')
    csrf = page.text.split('name="csrf" value="', 1)[1].split('"', 1)[0]
    assert client.post('/admin/categories', data={'title': '新分类', 'csrf': 'bad'}).status_code == 403
    added = client.post('/admin/categories', data={'title': '风景壁纸', 'csrf': csrf})
    assert added.status_code == 303
    categories = client.get('/v1/gallery/categories').json()['items']
    custom = categories[-1]
    assert custom['title'] == '风景壁纸' and custom['kind'] == 'catalog'
    assert '风景壁纸' in client.get('/admin/categories').text
    uploaded = client.post('/admin/assets', data={
        'csrf': csrf, 'collection': custom['id'], 'title': '山景', 'published': 'on'
    }, files={'file': ('landscape.jpg', jpeg_bytes(), 'image/jpeg')})
    assert uploaded.status_code == 303
    assert client.get('/v1/catalog/' + custom['id']).json()['items'][0]['title'] == '山景'
    edited = client.post('/admin/categories/' + custom['id'], data={
        'csrf': csrf, 'title': '风景精选', 'sort_order': 1
    })
    assert edited.status_code == 303
    from app.db import init_db
    init_db()
    categories = client.get('/v1/gallery/categories').json()['items']
    assert next(item for item in categories if item['id'] == custom['id'])['title'] == '风景精选'
    assert all(item['published'] == 1 for item in categories)
    secret = client.post('/admin/categories', data={'title': '内部图', 'csrf': csrf, 'hidden': '1', 'published': '1'})
    assert secret.status_code == 303
    hidden_item = next(item for item in client.get('/v1/gallery/categories').json()['items'] if item['title'] == '内部图')
    assert hidden_item['hidden'] == 1 and hidden_item['published'] == 1
    parked = client.post('/admin/categories', data={'title': '暂存分类', 'csrf': csrf, 'hidden': '0', 'published': '0'})
    assert parked.status_code == 303
    parked_id = parked.headers['location'].split('collection=', 1)[1].split('&', 1)[0]
    visible = client.get('/v1/gallery/categories').json()['items']
    assert all(item['id'] != parked_id for item in visible)
    assert client.get('/v1/catalog/' + parked_id).status_code == 404
    admin_page = client.get('/admin/categories')
    assert '暂存分类' in admin_page.text and '五连击后显示' in admin_page.text and '已下架' in admin_page.text
    assert client.post('/admin/categories/' + custom['id'], data={
        'csrf': csrf, 'title': '风景精选', 'sort_order': 1, 'hidden': '0', 'published': '0'
    }).status_code == 303
    assert all(item['id'] != custom['id'] for item in client.get('/v1/gallery/categories').json()['items'])
    assert client.get('/v1/catalog/' + custom['id']).status_code == 404
    assert client.get('/v1/catalog/not-a-category').status_code == 404
    assert client.get('/admin/categories/stock/source').status_code == 200

def test_stock_wallpapers_use_own_catalog(client: TestClient, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    root = tmp_path / 'seed'
    folder = root / 'Stock'
    folder.mkdir(parents=True)
    original = jpeg_bytes()
    (folder / 'WallpaperBlue-Dark.jpg').write_bytes(original)
    monkeypatch.setenv('CARVISTA_SEED', str(root))
    from app.seed import seed_wallpapers
    seed_wallpapers()
    item = client.get('/v1/catalog/stock').json()['items'][0]
    assert item['title'] == '蓝色 · 深色'
    assert '/v1/media/' in item['original_url']
    assert client.get(item['original_url']).content == original
    login(client)
    page = client.get('/admin/assets?collection=stock')
    assert page.status_code == 200 and '蓝色 · 深色' in page.text
    csrf = page.text.split('name="csrf" value="', 1)[1].split('"', 1)[0]
    client.post('/admin/assets/' + item['id'], data={'csrf': csrf, 'title': '自定义名称', 'published': 'on'})
    seed_wallpapers()
    assert client.get('/v1/catalog/stock').json()['items'][0]['title'] == '自定义名称'
    client.post('/admin/assets/' + item['id'] + '/delete', data={'csrf': csrf})
    seed_wallpapers()
    assert client.get('/v1/catalog/stock').json()['items'] == []

def test_test_wallpapers_are_hosted_by_backend(client: TestClient, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import json
    root = tmp_path / 'test-seed'
    folder = root / 'TestGallery'
    folder.mkdir(parents=True)
    (folder / '01.jpg').write_bytes(jpeg_bytes())
    (folder / 'catalog.json').write_text(json.dumps([
        {'id': '01', 'title': '测试海岸', 'file': '01.jpg', 'width': 32, 'height': 16}
    ]), encoding='utf-8')
    monkeypatch.setenv('CARVISTA_SEED', str(root))
    from app.seed import seed_wallpapers
    seed_wallpapers()
    seed_wallpapers()
    items = client.get('/v1/catalog/test').json()['items']
    assert len(items) == 1 and items[0]['title'] == '测试海岸'
    assert client.get(items[0]['original_url']).status_code == 200
    login(client)
    page = client.get('/admin/assets?collection=test')
    assert '测试海岸' in page.text
    csrf = page.text.split('name="csrf" value="', 1)[1].split('"', 1)[0]
    client.post('/admin/assets/' + items[0]['id'], data={'csrf': csrf, 'title': '后台修改', 'published': 'on'})
    seed_wallpapers()
    assert client.get('/v1/catalog/test').json()['items'][0]['title'] == '后台修改'
    client.post('/admin/assets/' + items[0]['id'] + '/delete', data={'csrf': csrf})
    seed_wallpapers()
    assert client.get('/v1/catalog/test').json()['items'] == []


def test_folder_upload_creates_series(client: TestClient) -> None:
    login(client)
    page = client.get("/admin/categories")
    csrf = page.text.split('name="csrf" value="', 1)[1].split('"', 1)[0]
    added = client.post("/admin/categories", data={"title": "系列壁纸", "csrf": csrf, "hidden": "0", "published": "1"})
    assert added.status_code == 303
    parent = added.headers["location"].split("collection=", 1)[1].split("&", 1)[0]
    uploaded = client.post("/admin/assets/batch", data={
        "csrf": csrf, "collection": parent, "mode": "folders",
        "paths": ["系列壁纸/海滩/海.jpg", "系列壁纸/城市/城.jpg", "系列壁纸/海滩/海.jpg"],
    }, files=[
        ("files", ("海.jpg", jpeg_bytes(), "image/jpeg")),
        ("files", ("城.jpg", jpeg_bytes(40, 20), "image/jpeg")),
        ("files", ("海.jpg", jpeg_bytes(), "image/jpeg")),
    ])
    assert uploaded.status_code == 200
    assert uploaded.json() == {"added": 2, "skipped": 1, "failed": 0}
    titles = [item["title"] for item in client.get("/v1/gallery/categories").json()["items"]]
    assert "系列壁纸" in titles and "海滩" not in titles and "城市" not in titles
    groups = client.get(f"/v1/gallery/categories/{parent}/groups").json()["items"]
    assert [item["title"] for item in groups] == ["海滩", "城市"]
    assert groups[0]["count"] == 1 and groups[0]["preview_url"]
    beach = client.get("/v1/catalog/" + groups[0]["id"]).json()["items"]
    assert beach[0]["title"] == "海"
    admin = client.get("/admin/assets?collection=" + parent)
    assert "选择文件夹" in admin.text and "海滩" in admin.text
    assert "改名" in admin.text
    beach_id = groups[0]["id"]
    renamed = client.post("/admin/categories/" + beach_id, data={
        "csrf": csrf,
        "title": "碧海",
        "sort_order": "1",
        "hidden": "0",
        "published": "1",
        "return_collection": parent,
    }, follow_redirects=False)
    assert renamed.status_code == 303
    assert "collection=" + parent in renamed.headers["location"]
    groups = client.get(f"/v1/gallery/categories/{parent}/groups").json()["items"]
    assert groups[0]["title"] == "碧海"
    child_page = client.get("/admin/assets?collection=" + groups[0]["id"])
    assert "系列名称" in child_page.text and "碧海" in child_page.text
    flat = client.post("/admin/assets/batch", data={
        "csrf": csrf, "collection": groups[1]["id"], "mode": "files", "paths": ["夜.jpg"],
    }, files=[("files", ("夜.jpg", jpeg_bytes(24, 12), "image/jpeg"))])
    assert flat.json()["added"] == 1
    assert client.get("/v1/catalog/" + groups[1]["id"]).json()["items"][-1]["title"] == "夜"
    removed = client.post("/admin/categories/" + groups[0]["id"] + "/delete", data={"csrf": csrf}, follow_redirects=False)
    assert removed.status_code == 303
    assert "collection=" + parent in removed.headers["location"]
    left = client.get(f"/v1/gallery/categories/{parent}/groups").json()["items"]
    assert [item["title"] for item in left] == ["城市"]
    assert client.get("/v1/catalog/" + groups[0]["id"]).status_code == 404