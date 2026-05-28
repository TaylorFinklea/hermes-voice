import io

from tests.conftest import FakeHermes, build_client


class StubSTT:
    name = "stub"

    def describe(self) -> dict:
        return {"name": self.name}

    async def transcribe(self, audio_bytes, *, mime=None):
        return f"heard {len(audio_bytes)} bytes"


def _wav_upload(bytes_: bytes = b"RIFF\x00\x00\x00\x00WAVE"):
    return {"file": ("clip.wav", io.BytesIO(bytes_), "audio/wav")}


def test_audio_endpoint_requires_stt_provider():
    client = build_client(hermes=FakeHermes(), stt=None, tts=None)
    resp = client.post("/api/audio", files=_wav_upload())
    assert resp.status_code == 503
    assert "STT" in resp.json()["detail"]


def test_audio_endpoint_transcribes_and_calls_hermes():
    hermes = FakeHermes(reply="okay")
    client = build_client(hermes=hermes, stt=StubSTT(), tts=None)
    resp = client.post("/api/audio", files=_wav_upload(b"x" * 1024))
    assert resp.status_code == 200
    body = resp.json()
    assert body["user_text"] == "heard 1024 bytes"
    assert body["assistant_text"] == "okay"
    assert hermes.calls[0][0] == "heard 1024 bytes"


def test_audio_endpoint_rejects_oversized_upload():
    huge = b"\x00" * (26 * 1024 * 1024)
    client = build_client(hermes=FakeHermes(), stt=StubSTT(), tts=None)
    resp = client.post(
        "/api/audio",
        files={"file": ("big.wav", io.BytesIO(huge), "audio/wav")},
    )
    assert resp.status_code == 413
