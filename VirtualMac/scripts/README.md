# Scripts

Run `../setup.sh` for a complete reproducible build. The scripts directly in this directory are the stages used for building a deb package; they may also be run individually after the environment has been prepared.

- `development/` contains USB deployment, bring-up, and interactive device/real-Mac helpers.
- `tests/` contains test and benchmark harnesses.
- `research/` contains static analysis, tracing, and reverse-engineering helpers.
- `lib/` contains shared implementation used by all three groups and the release build.

All scripts resolve the project directory from their own location. They do not depend on the checkout’s absolute path.
