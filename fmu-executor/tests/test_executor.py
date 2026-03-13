"""Tests for the FMU Executor internal API.

These tests use FastAPI TestClient with a mock FMU to validate the internal
contract that Lab Gateway's fmu-runner expects from the station backend.
"""

from __future__ import annotations

import json
import os
import shutil
import tempfile
from pathlib import Path
from unittest.mock import patch, MagicMock

import pytest
from fastapi.testclient import TestClient


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def _isolate_config(tmp_path: Path):
    """Point config at a temporary FMU root and reset sessions between tests."""
    fmu_root = tmp_path / "fmu-data"
    fmu_root.mkdir()
    temp_dir = tmp_path / "tmp"
    temp_dir.mkdir()

    with patch.dict(os.environ, {
        "FMU_ROOT": str(fmu_root),
        "FMU_EXECUTOR_TEMP": str(temp_dir),
        "FMU_INTERNAL_TOKEN": "test-secret",
        "FMU_MAX_SESSIONS": "4",
        "FMU_LOG_LEVEL": "WARNING",
    }):
        # Re-import config so the patched env takes effect
        import importlib
        from app import config as cfg
        importlib.reload(cfg)
        yield fmu_root
    # Cleanup all sessions
    from app.engine import terminate_all
    terminate_all()


@pytest.fixture
def client():
    from app.main import app
    return TestClient(app)


@pytest.fixture
def auth_headers():
    return {"X-Internal-Session-Token": "test-secret"}


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

class TestHealth:
    def test_health_returns_ok(self, client, auth_headers):
        resp = client.get("/internal/health")
        assert resp.status_code == 200
        body = resp.json()
        assert body["status"] == "ok"
        assert "fmuCount" in body
        assert "activeSessions" in body

    def test_health_no_auth_required(self, client):
        """Health endpoint doesn't require internal token."""
        resp = client.get("/internal/health")
        assert resp.status_code == 200


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

class TestAuth:
    def test_describe_requires_token(self, client):
        resp = client.get("/internal/fmu/describe/test.fmu")
        assert resp.status_code == 401

    def test_describe_rejects_wrong_token(self, client):
        resp = client.get(
            "/internal/fmu/describe/test.fmu",
            headers={"X-Internal-Session-Token": "wrong"},
        )
        assert resp.status_code == 401

    def test_catalog_requires_token(self, client):
        resp = client.get("/internal/fmu/catalog/test.fmu")
        assert resp.status_code == 401


# ---------------------------------------------------------------------------
# Describe / Catalog – 404 when FMU missing
# ---------------------------------------------------------------------------

class TestDescribe:
    def test_describe_404_when_missing(self, client, auth_headers):
        resp = client.get("/internal/fmu/describe/nonexistent.fmu", headers=auth_headers)
        assert resp.status_code == 404

    def test_catalog_404_when_missing(self, client, auth_headers):
        resp = client.get("/internal/fmu/catalog/nonexistent.fmu", headers=auth_headers)
        assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Describe / Catalog – with a mock FMU
# ---------------------------------------------------------------------------

class TestDescribeWithFmu:
    """Tests that use a mocked fmpy.read_model_description."""

    def _mock_model_description(self):
        md = MagicMock()
        md.modelName = "TestModel"
        md.guid = "{test-guid-1234}"
        md.fmiVersion = "2.0"
        md.coSimulation = MagicMock()
        md.coSimulation.modelIdentifier = "TestModel"
        md.modelExchange = None
        md.defaultExperiment = MagicMock()
        md.defaultExperiment.startTime = "0.0"
        md.defaultExperiment.stopTime = "1.0"
        md.defaultExperiment.stepSize = "0.01"

        var1 = MagicMock()
        var1.name = "x"
        var1.valueReference = 0
        var1.causality = "output"
        var1.variability = "continuous"
        var1.type = "Real"
        var1.start = None
        var1.unit = "m"
        var1.min = None
        var1.max = None

        var2 = MagicMock()
        var2.name = "u"
        var2.valueReference = 1
        var2.causality = "input"
        var2.variability = "continuous"
        var2.type = "Real"
        var2.start = "0.0"
        var2.unit = None
        var2.min = None
        var2.max = None

        md.modelVariables = [var1, var2]
        return md

    def test_describe_returns_model_info(self, client, auth_headers, _isolate_config):
        fmu_root = _isolate_config
        # Create a dummy .fmu file
        dummy_fmu = fmu_root / "TestModel.fmu"
        dummy_fmu.write_bytes(b"PK\x03\x04dummy")

        md = self._mock_model_description()
        with patch("fmpy.read_model_description", return_value=md):
            resp = client.get("/internal/fmu/describe/TestModel.fmu", headers=auth_headers)

        assert resp.status_code == 200
        body = resp.json()
        assert body["modelName"] == "TestModel"
        assert body["guid"] == "{test-guid-1234}"
        assert body["fmiVersion"] == "2.0"
        assert body["supportsCoSimulation"] is True
        assert body["supportsModelExchange"] is False
        assert body["fmiType"] == "CoSimulation"
        assert len(body["modelVariables"]) == 2
        assert body["defaultStartTime"] == 0.0
        assert body["defaultStopTime"] == 1.0
        assert body["defaultStepSize"] == 0.01

    def test_catalog_returns_files_and_describe(self, client, auth_headers, _isolate_config):
        fmu_root = _isolate_config
        dummy_fmu = fmu_root / "TestModel.fmu"
        dummy_fmu.write_bytes(b"PK\x03\x04dummy")

        md = self._mock_model_description()
        with patch("fmpy.read_model_description", return_value=md):
            resp = client.get("/internal/fmu/catalog/TestModel.fmu", headers=auth_headers)

        assert resp.status_code == 200
        body = resp.json()
        assert body["accessKey"] == "TestModel.fmu"
        assert "TestModel.fmu" in body["files"]
        assert body["describe"]["modelName"] == "TestModel"


# ---------------------------------------------------------------------------
# FMU storage - path traversal protection
# ---------------------------------------------------------------------------

class TestPathTraversal:
    def test_traversal_blocked(self, client, auth_headers, _isolate_config):
        resp = client.get("/internal/fmu/describe/..%2F..%2Fetc%2Fpasswd", headers=auth_headers)
        assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Run simulation – 404 when FMU missing
# ---------------------------------------------------------------------------

class TestRunSimulation:
    def test_run_404_when_fmu_missing(self, client, auth_headers):
        resp = client.post(
            "/internal/fmu/simulations/run/missing.fmu",
            headers=auth_headers,
            json={"parameters": {}, "options": {"stopTime": 0.5}},
        )
        assert resp.status_code == 404

    def test_stream_404_when_fmu_missing(self, client, auth_headers):
        resp = client.post(
            "/internal/fmu/simulations/stream/missing.fmu",
            headers=auth_headers,
            json={"parameters": {}, "options": {"stopTime": 0.5}},
        )
        assert resp.status_code == 404


# ---------------------------------------------------------------------------
# WebSocket – auth validation
# ---------------------------------------------------------------------------

class TestWebSocketAuth:
    def test_ws_rejects_missing_token(self, client):
        from starlette.websockets import WebSocketDisconnect
        with pytest.raises(WebSocketDisconnect) as exc_info:
            with client.websocket_connect("/internal/fmu/sessions"):
                pass
        assert exc_info.value.code == 4001

    def test_ws_rejects_wrong_token(self, client):
        from starlette.websockets import WebSocketDisconnect
        with pytest.raises(WebSocketDisconnect) as exc_info:
            with client.websocket_connect(
                "/internal/fmu/sessions",
                headers={"X-Internal-Session-Token": "wrong"},
            ):
                pass
        assert exc_info.value.code == 4001


# ---------------------------------------------------------------------------
# WebSocket – session lifecycle (with mock)
# ---------------------------------------------------------------------------

class TestWebSocketSession:
    def test_session_create_requires_gateway_context(self, client, auth_headers):
        with client.websocket_connect(
            "/internal/fmu/sessions",
            headers={"X-Internal-Session-Token": "test-secret"}
        ) as ws:
            ws.send_text(json.dumps({
                "type": "session.create",
                "requestId": "req1",
            }))
            resp = json.loads(ws.receive_text())
            assert resp["type"] == "error"
            assert resp["requestId"] == "req1"

    def test_session_create_validates_access_key(self, client):
        with client.websocket_connect(
            "/internal/fmu/sessions",
            headers={"X-Internal-Session-Token": "test-secret"}
        ) as ws:
            ws.send_text(json.dumps({
                "type": "session.create",
                "requestId": "req2",
                "gatewayContext": {
                    "mode": "station",
                    "accessKey": "nonexistent.fmu",
                    "claims": {},
                },
            }))
            resp = json.loads(ws.receive_text())
            assert resp["type"] == "error"
            assert "FMU_NOT_FOUND" in resp.get("code", "")

    def test_ping_pong_without_session(self, client):
        with client.websocket_connect(
            "/internal/fmu/sessions",
            headers={"X-Internal-Session-Token": "test-secret"}
        ) as ws:
            ws.send_text(json.dumps({
                "type": "session.ping",
                "requestId": "ping1",
            }))
            resp = json.loads(ws.receive_text())
            # ping requires a session in current implementation, so it should error
            assert resp["requestId"] == "ping1"


# ---------------------------------------------------------------------------
# FMU listing
# ---------------------------------------------------------------------------

class TestFmuListing:
    def test_list_empty(self, _isolate_config):
        from app import fmu_storage
        assert fmu_storage.list_fmus() == []

    def test_list_detects_fmu_files(self, _isolate_config):
        fmu_root = _isolate_config
        (fmu_root / "Model1.fmu").write_bytes(b"PK")
        (fmu_root / "Model2.fmu").write_bytes(b"PK")
        (fmu_root / "readme.txt").write_text("not an fmu")

        from app import fmu_storage
        keys = fmu_storage.list_fmus()
        assert "Model1.fmu" in keys
        assert "Model2.fmu" in keys
        assert "readme.txt" not in keys

    def test_list_detects_fmu_in_subdirs(self, _isolate_config):
        fmu_root = _isolate_config
        sub = fmu_root / "my-model"
        sub.mkdir()
        (sub / "model.fmu").write_bytes(b"PK")

        from app import fmu_storage
        keys = fmu_storage.list_fmus()
        assert "my-model" in keys
