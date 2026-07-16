import ast
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def test_bot_main_uses_runtime_status_writer_after_module_split():
    source = (PROJECT_ROOT / "bot.py").read_text(encoding="utf-8")
    tree = ast.parse(source)
    main_function = next(
        node
        for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name == "main"
    )
    calls = [node for node in ast.walk(main_function) if isinstance(node, ast.Call)]

    assert any(
        isinstance(call.func, ast.Attribute)
        and call.func.attr == "write_idle_if_no_active_task"
        and isinstance(call.func.value, ast.Name)
        and call.func.value.id == "RUNTIME_STATUS"
        for call in calls
    )
    assert not any(
        isinstance(call.func, ast.Name)
        and call.func.id == "write_idle_runtime_status_if_no_active_task"
        for call in calls
    )
