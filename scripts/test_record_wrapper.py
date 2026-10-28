import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TEST = os.path.join(ROOT, "npm", "qenome", "test", "d1.test.mjs")


def main():
    node = shutil.which("node")
    if node is None:
        print("skip: the record wrapper test needs node")
        return 0
    done = subprocess.run(
        [node, TEST],
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    sys.stdout.write(done.stdout)
    sys.stderr.write(done.stderr)
    if done.returncode != 0:
        return done.returncode
    if "record wrapper: ok" not in done.stdout:
        sys.stderr.write("record wrapper: the node test did not finish\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
