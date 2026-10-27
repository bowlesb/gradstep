"""Offline, constrained TeX command used only by optional render scoring."""
from __future__ import annotations
import os
from pathlib import Path

IMAGE = "gradstep-tex:v1"

def docker_cmd(workdir: Path, cmd: list[str], timeout: int, memory: str = "4g", cpus: str = "2") -> list[str]:
    return [
        "docker", "run", "--rm", "--init", "--network", "none", "--read-only",
        "--tmpfs", "/tmp:rw,exec,size=2g",
        "--memory", memory, "--cpus", cpus, "--pids-limit", "512",
        "--security-opt", "no-new-privileges", "--cap-drop", "ALL",
        "-u", f"{os.getuid()}:{os.getgid()}",
        "-v", f"{workdir}:/paper", "-w", "/paper",
        IMAGE, "timeout", "-k", "15", str(timeout), *cmd,
    ]
