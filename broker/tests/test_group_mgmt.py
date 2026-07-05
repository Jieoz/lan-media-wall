"""Explicit group management (§18) + configure_device registry effects (§19)."""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import registry as registry_mod  # noqa: E402


def _reg():
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    os.unlink(path)  # start empty; registry writes on demand
    return registry_mod.Registry(path), path


def test_create_group_appears_empty_in_snapshot():
    reg, path = _reg()
    try:
        created = reg.create_group("hall-2", name="二号厅", sync=True)
        assert created is True
        snap = {g["group_id"]: g for g in reg.groups_snapshot()}
        assert "hall-2" in snap
        assert snap["hall-2"]["name"] == "二号厅"
        assert snap["hall-2"]["sync"] is True
        assert snap["hall-2"]["members"] == []  # empty group, the whole point
    finally:
        os.path.exists(path) and os.unlink(path)


def test_create_group_is_idempotent():
    reg, path = _reg()
    try:
        assert reg.create_group("g1", name="A") is True
        assert reg.create_group("g1", name="B") is False  # already exists
        snap = {g["group_id"]: g for g in reg.groups_snapshot()}
        assert snap["g1"]["name"] == "B"  # meta merged
    finally:
        os.path.exists(path) and os.unlink(path)


def test_update_group_only_changes_given_fields():
    reg, path = _reg()
    try:
        reg.create_group("g1", name="原名", sync=True)
        assert reg.update_group("g1", sync=False) is True
        snap = {g["group_id"]: g for g in reg.groups_snapshot()}
        assert snap["g1"]["name"] == "原名"    # untouched
        assert snap["g1"]["sync"] is False     # changed
    finally:
        os.path.exists(path) and os.unlink(path)


def test_update_missing_group_returns_false():
    reg, path = _reg()
    try:
        assert reg.update_group("nope", name="x") is False
    finally:
        os.path.exists(path) and os.unlink(path)


def test_delete_group_reassigns_members_to_default():
    reg, path = _reg()
    try:
        reg.register("dev-1", group_id="hall-2")
        reg.register("dev-2", group_id="hall-2")
        reg.create_group("hall-2", name="二号厅")
        reassigned = reg.delete_group("hall-2")
        assert set(reassigned) == {"dev-1", "dev-2"}
        # members fell back to default; the group is gone from meta.
        assert reg.get("dev-1").group_id == registry_mod.DEFAULT_GROUP
        assert reg.get("dev-2").group_id == registry_mod.DEFAULT_GROUP
        gids = {g["group_id"] for g in reg.groups_snapshot()}
        assert "hall-2" not in gids
    finally:
        os.path.exists(path) and os.unlink(path)


def test_delete_group_custom_reassign_target():
    reg, path = _reg()
    try:
        reg.register("dev-1", group_id="hall-2")
        reg.create_group("hall-3", name="三号厅")
        reg.delete_group("hall-2", reassign_to="hall-3")
        assert reg.get("dev-1").group_id == "hall-3"
    finally:
        os.path.exists(path) and os.unlink(path)


def test_default_group_cannot_be_deleted():
    reg, path = _reg()
    try:
        reg.register("dev-1", group_id=registry_mod.DEFAULT_GROUP)
        reassigned = reg.delete_group(registry_mod.DEFAULT_GROUP)
        assert reassigned == []
        assert reg.get("dev-1").group_id == registry_mod.DEFAULT_GROUP
    finally:
        os.path.exists(path) and os.unlink(path)


def test_group_meta_persists_across_reload():
    reg, path = _reg()
    try:
        reg.create_group("hall-2", name="二号厅", sync=False)
        # New Registry instance over the same state file -> reload.
        reg2 = registry_mod.Registry(path)
        snap = {g["group_id"]: g for g in reg2.groups_snapshot()}
        assert snap["hall-2"]["name"] == "二号厅"
        assert snap["hall-2"]["sync"] is False
    finally:
        os.path.exists(path) and os.unlink(path)
