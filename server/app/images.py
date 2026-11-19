# SPDX-License-Identifier: GPL-3.0-or-later
import io
from pathlib import Path

from PIL import Image, UnidentifiedImageError

MAX_BYTES = 40 * 1024 * 1024
MAX_PIXELS = 80_000_000
PREVIEW_EDGE = 960


class ImageRejected(ValueError):
    pass


def valid_preview(data: bytes) -> None:
    if not data or len(data) > 2 * 1024 * 1024:
        raise ImageRejected("预览图无效")
    try:
        probe = Image.open(io.BytesIO(data))
        probe.verify()
    except (UnidentifiedImageError, OSError) as error:
        raise ImageRejected("预览图无效") from error


def store_original(data: bytes, original: Path, preview: Path) -> tuple[int, int]:
    if not data:
        raise ImageRejected("文件是空的")
    if len(data) > MAX_BYTES:
        raise ImageRejected("文件超过 40MB")
    try:
        probe = Image.open(io.BytesIO(data))
        probe.verify()
        image = Image.open(io.BytesIO(data))
        image.load()
    except (UnidentifiedImageError, OSError) as error:
        raise ImageRejected("无法读取图片，请上传 JPEG 或 PNG") from error
    if image.format not in {"JPEG", "PNG"}:
        raise ImageRejected("只接受 JPEG 或 PNG")
    if image.width < 1 or image.height < 1 or image.width * image.height > MAX_PIXELS:
        raise ImageRejected("图片尺寸无效或像素过多")
    original.parent.mkdir(parents=True, exist_ok=True)
    original.write_bytes(data)
    thumb = image.convert("RGB")
    thumb.thumbnail((PREVIEW_EDGE, PREVIEW_EDGE), Image.Resampling.LANCZOS)
    preview.parent.mkdir(parents=True, exist_ok=True)
    thumb.save(preview, "JPEG", quality=80, optimize=True)
    return image.width, image.height


def safe_file(root: Path, stored: str | None) -> Path | None:
    if not stored:
        return None
    path = Path(stored).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError:
        return None
    if not path.is_file():
        return None
    return path
