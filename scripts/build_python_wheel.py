"""Build an interpreter-specific wheel with a relocatable Mojo runtime path."""

from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parents[1]
    arguments = sys.argv[1:]
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]
    if sys.platform == "linux":
        default_platform = f"manylinux_2_34_{platform.machine()}"
    else:
        default_platform = "macosx_13_0_arm64"
    wheel_platform = arguments[0] if arguments else default_platform
    extension = root / "python/blazeseq/_extension/blazeseq_parser.so"
    mojo = ["pixi", "run", "--frozen", "-e", "dev", "mojo"]
    target_flags = (
        ["--target-triple=arm64-apple-macosx13.0"] if sys.platform == "darwin" else []
    )
    subprocess.run(
        [
            *mojo,
            "build",
            *target_flags,
            "--Werror",
            "-I",
            ".",
            "--emit",
            "shared-lib",
            "-o",
            str(extension),
            "python/blazeseq_parser.mojo",
        ],
        cwd=root,
        check=True,
    )
    if sys.platform == "linux":
        # The required mojo-compiler wheel installs its runtime under modular/lib.
        subprocess.run(
            ["patchelf", "--set-rpath", "$ORIGIN/../../modular/lib", str(extension)],
            check=True,
        )
        versions = subprocess.check_output(
            ["readelf", "--version-info", str(extension)], text=True
        )
        glibc = [
            tuple(map(int, match.split(".")))
            for match in re.findall(r"GLIBC_([0-9.]+)", versions)
        ]
        if glibc and max(glibc) > (2, 34):
            raise RuntimeError(
                "The extension requires glibc newer than the wheel's 2.34 platform tag"
            )
    elif sys.platform == "darwin":
        dependencies = subprocess.check_output(
            ["otool", "-L", str(extension)], text=True
        ).splitlines()[1:]
        for line in dependencies:
            dependency = line.strip().split(" ", 1)[0]
            if "/.pixi/" in dependency:
                subprocess.run(
                    [
                        "install_name_tool",
                        "-change",
                        dependency,
                        "@rpath/" + Path(dependency).name,
                        str(extension),
                    ],
                    check=True,
                )
        load_commands = subprocess.check_output(
            ["otool", "-l", str(extension)], text=True
        )
        for path in re.findall(
            r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", load_commands
        ):
            subprocess.run(
                ["install_name_tool", "-delete_rpath", path, str(extension)], check=True
            )
        subprocess.run(
            [
                "install_name_tool",
                "-add_rpath",
                "@loader_path/../../modular/lib",
                str(extension),
            ],
            check=True,
        )
    else:
        raise RuntimeError("BlazeSeq wheels support Linux and Apple Silicon macOS")
    subprocess.run(
        [
            *mojo,
            "precompile",
            "--Werror",
            "-I",
            ".",
            "blazeseq",
            "-o",
            "python/blazeseq/mojoc/blazeseq.mojoc",
        ],
        cwd=root,
        check=True,
    )
    for directory in ["python/build", "python/blazeseq.egg-info"]:
        shutil.rmtree(root / directory, ignore_errors=True)
    subprocess.run(
        [
            "uv",
            "build",
            "--wheel",
            f"--config-setting=--build-option=--plat-name={wheel_platform}",
        ],
        cwd=root / "python",
        check=True,
    )


if __name__ == "__main__":
    main()
