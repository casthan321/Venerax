from build_windows import build


# The shared builder deliberately rejects cross-packaging on x64 Windows.
# Flutter selects the Windows target from the native host architecture and the
# installed SDK does not support a Windows `--target-platform` override.


if __name__ == "__main__":
    try:
        build("arm64")
    except RuntimeError as error:
        raise SystemExit(f"ARM64 packaging refused: {error}") from None
