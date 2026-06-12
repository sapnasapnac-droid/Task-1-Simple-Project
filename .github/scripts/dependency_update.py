#!/usr/bin/env python3
"""
dependency_update.py

Self-healing dependency updater with bisection-based fault localization.
Python port of the original inline-bash workflow step.

Behaviour is the same as the bash version:
  - probe every available bump up front
  - update -> install -> build -> test in a retry loop (max 20 attempts)
  - on install conflict (ERESOLVE), reject the owned conflicting package and retry
  - on build/test failure, bisect the major bumps to find the culprit, reject, retry
  - build failure with nothing to roll back -> hard fail
  - test failure with nothing to roll back -> still open the PR, flagged for review

Required environment (set by the calling workflow step):
  UPDATE_LEVEL   - one of: patch | minor | latest
  GITHUB_OUTPUT  - file path GitHub Actions provides for step outputs (optional locally)

Stdlib only - no pip install needed. Shells out to: npm, ncu, git is handled in YAML.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time

# ---------- Config ----------
TARGET = os.environ.get("UPDATE_LEVEL", "minor")
MAX_ATTEMPTS = 20
BISECT_MAX_DEPTH = 4  # 0 disables bisection (old hammer)

PKG = "package.json"
LOCK = "package-lock.json"
PKG_ORIG = "/tmp/pkg.orig"
LOCK_ORIG = "/tmp/lock.orig"
PROBE_FILE = "/tmp/probe.json"


# ---------- Small logging helpers (GitHub Actions annotations) ----------
def log(msg=""):
    print(msg, flush=True)


def group(msg):
    print(f"::group::{msg}", flush=True)


def endgroup():
    print("::endgroup::", flush=True)


def notice(msg):
    print(f"::notice::{msg}", flush=True)


def warning(msg):
    print(f"::warning::{msg}", flush=True)


def die(msg, extra=""):
    print(f"::error::{msg}", flush=True)
    if extra:
        print(extra, flush=True)
    sys.exit(1)


# ---------- Subprocess helpers ----------
def run(args, log_path=None, echo=False):
    """Run a command, capture combined output. Returns (returncode, output)."""
    proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    out = proc.stdout or ""
    if log_path:
        with open(log_path, "w") as fh:
            fh.write(out)
    if echo and out:
        print(out, end="", flush=True)
    return proc.returncode, out


def ncu_update(reject=None):
    """Run `ncu -u` (optionally with --reject), quietly. Failures are tolerated."""
    cmd = ["ncu", "-u", "--target", TARGET]
    if reject:
        cmd += ["--reject", ",".join(reject)]
    run(cmd)  # output suppressed, like the bash `>&2 || true`


# ---------- package.json helpers ----------
def load_json(path):
    with open(path) as fh:
        return json.load(fh)


def all_deps(doc):
    """dependencies + devDependencies merged into one {name: version} dict."""
    deps = {}
    for key in ("dependencies", "devDependencies"):
        block = doc.get(key)
        if isinstance(block, dict):
            deps.update(block)
    return deps


def major(version):
    """Major component of a semver-ish string, or None if it doesn't parse."""
    if not isinstance(version, str):
        return None
    stripped = version.lstrip("~^><= ")
    return stripped.split(".")[0] if stripped else None


class Updater:
    def __init__(self, probe, our_deps, has_build, has_test):
        self.probe = probe              # {name: upgraded_version}
        self.our_deps = our_deps        # set of package names we own
        self.has_build = has_build
        self.has_test = has_test
        self.reject_list = []           # packages proven problematic this run
        self.current_majors = []        # major-bumped packages for the active bisect
        self.trial_cache = {}           # key -> "pass"/"fail"
        self.trial_count = 0
        self.test_outcome = "skipped"
        self.final_attempt = 0

    # ---------- baseline restore ----------
    def restore_baseline(self):
        shutil.copy(PKG_ORIG, PKG)
        shutil.copy(LOCK_ORIG, LOCK)

    # ---------- analysis ----------
    def identify_major_bumps(self):
        """Packages whose major version changed vs the baseline."""
        orig = all_deps(load_json(PKG_ORIG))
        cur = all_deps(load_json(PKG))
        out = []
        for name, new_v in cur.items():
            if not isinstance(new_v, str):
                continue
            old_v = orig.get(name)
            if not isinstance(old_v, str):
                continue
            nm, om = major(new_v), major(old_v)
            if nm is not None and om is not None and nm != om:
                out.append(name)
        return out

    def filter_new_rejections(self, candidates):
        """Keep only packages not already on the reject list."""
        return [p for p in candidates if p and p not in self.reject_list]

    # ---------- bisection ----------
    def try_majors(self, apply_majors, phase):
        """Apply ONLY these majors (hold back the rest + reject_list), then
        install/build/(test). Returns 'pass' or 'fail'. Memoized."""
        self.trial_count += 1
        n = self.trial_count
        key = phase + "|" + ",".join(sorted(p for p in apply_majors if p))

        if key in self.trial_cache:
            cached = self.trial_cache[key]
            group(f"Trial #{n} (cached) phase={phase} apply=[{','.join(apply_majors)}] -> {cached}")
            endgroup()
            return cached

        group(f"Trial #{n} phase={phase} apply=[{','.join(apply_majors)}]")

        shutil.rmtree("node_modules", ignore_errors=True)
        self.restore_baseline()

        reject_for_trial = list(self.reject_list)
        for m in self.current_majors:
            if m and m not in apply_majors:
                reject_for_trial.append(m)

        ncu_update(reject_for_trial if reject_for_trial else None)

        result = "pass"
        rc, _ = run(["npm", "install"], log_path="/tmp/bisect.log")
        if rc != 0:
            log("Install failed in trial")
            result = "fail"
        elif self.has_build:
            rc, _ = run(["npm", "run", "build"], log_path="/tmp/bisect.log")
            if rc != 0:
                log("Build failed in trial")
                result = "fail"
        if result == "pass" and phase == "test" and self.has_test:
            rc, _ = run(["npm", "test"], log_path="/tmp/bisect.log")
            if rc != 0:
                log("Test failed in trial")
                result = "fail"

        self.trial_cache[key] = result
        log(f"Result: {result}")
        endgroup()
        return result

    def bisect_culprits(self, candidates, phase, depth=0):
        """Divide-and-conquer fault localization. Returns the offending packages."""
        candidates = [c for c in candidates if c]
        count = len(candidates)

        if count <= 1:
            return candidates
        if depth >= BISECT_MAX_DEPTH:
            warning(f"Bisect depth cap at depth={depth} - rejecting remaining: {','.join(candidates)}")
            return candidates

        half = count // 2
        half_a = candidates[:half]
        half_b = candidates[half:]

        result_a = self.try_majors(half_a, phase)
        result_b = self.try_majors(half_b, phase)

        if result_a == "pass" and result_b == "pass":
            warning(f"Both halves passed at depth={depth} - re-running once for flake check")
            result_a = self.try_majors(half_a, phase)
            result_b = self.try_majors(half_b, phase)
            if result_a == "pass" and result_b == "pass":
                return []

        culprits = []
        if result_a == "fail":
            culprits += self.bisect_culprits(half_a, phase, depth + 1)
        if result_b == "fail":
            culprits += self.bisect_culprits(half_b, phase, depth + 1)

        return sorted(set(c for c in culprits if c))

    def locate_and_confirm(self, candidates, phase):
        """Bisect, then confirm that holding back only the culprits actually fixes it."""
        if BISECT_MAX_DEPTH <= 0:
            return candidates

        culprits = self.bisect_culprits(candidates, phase, 0)
        if not culprits:
            warning("Bisection nominated no culprits - falling back to full set")
            return candidates

        non_culprits = [c for c in candidates if c and c not in culprits]
        verify = self.try_majors(non_culprits, phase)
        if verify == "fail":
            warning("Confirmation failed (likely interaction effects) - falling back to full set")
            return candidates

        return culprits

    # ---------- main self-healing loop ----------
    def run_loop(self):
        for attempt in range(1, MAX_ATTEMPTS + 1):
            log("")
            log(f"===== Attempt {attempt} of {MAX_ATTEMPTS} =====")
            self.final_attempt = attempt

            for d in ("node_modules", "lib", "dist"):
                shutil.rmtree(d, ignore_errors=True)
            self.restore_baseline()

            if self.reject_list:
                log(f"Rejecting: {','.join(self.reject_list)}")
                ncu_update(self.reject_list)
            else:
                ncu_update()

            # ----- Install -----
            rc, install_log = run(["npm", "install"], log_path="/tmp/install.log", echo=True)
            if rc != 0:
                if re.search(r"ETIMEDOUT|ECONNRESET|ENOTFOUND|EAI_AGAIN", install_log):
                    warning("Network issue, retrying in 10s")
                    time.sleep(10)
                    continue
                if "ERESOLVE" not in install_log:
                    die("Non-ERESOLVE install failure", install_log)

                candidates = self.scrape_conflicts(install_log)
                owned = [p for p in candidates if p in self.our_deps]
                new = self.filter_new_rejections(owned)
                if not new:
                    die("ERESOLVE conflict with no actionable packages", install_log)
                self.reject_list += new
                log(f"Reject (install conflict): {','.join(new)}")
                continue

            # ----- Build -----
            if self.has_build:
                log("Running build...")
                rc, build_log = run(["npm", "run", "build"], log_path="/tmp/build.log", echo=True)
                if rc == 0:
                    log("Build succeeded")
                else:
                    self.current_majors = self.identify_major_bumps()
                    if not self.current_majors:
                        die("Build failed and no major bumps left to roll back", build_log)
                    log(f"Bisecting build culprits among: {','.join(self.current_majors)}")
                    culprits = self.locate_and_confirm(self.current_majors, "build")
                    new = self.filter_new_rejections(culprits)
                    if not new:
                        die("Build failed and bisection returned nothing actionable", build_log)
                    self.reject_list += new
                    log(f"Reject (build failure, bisected): {','.join(new)}")
                    continue

            # ----- Test -----
            if self.has_test:
                log("Running tests...")
                rc, _ = run(["npm", "test"], log_path="/tmp/test.log", echo=True)
                if rc == 0:
                    log("Tests passed")
                    self.test_outcome = "success"
                else:
                    self.current_majors = self.identify_major_bumps()
                    if self.current_majors:
                        log(f"Bisecting test culprits among: {','.join(self.current_majors)}")
                        culprits = self.locate_and_confirm(self.current_majors, "test")
                        new = self.filter_new_rejections(culprits)
                        if new:
                            self.reject_list += new
                            log(f"Reject (test failure, bisected): {','.join(new)}")
                            continue
                    warning("Tests still failing with no actionable rollbacks - shipping PR for human review")
                    self.test_outcome = "failure"

            return True  # converged

        return False  # never converged

    @staticmethod
    def scrape_conflicts(install_log):
        """Pull conflicting package names out of an npm ERESOLVE log."""
        found = []
        found += re.findall(r"Conflicting peer dependency: ([@a-z0-9/-]+)", install_log)
        found += re.findall(r"peer ([@a-z0-9/-]+)@", install_log)
        found += re.findall(r"Found: ([@a-z0-9/-]+)@", install_log)
        return sorted(set(found))

    # ---------- report ----------
    def reject_details(self):
        """Markdown bullets of held-back packages: old -> available version."""
        old = all_deps(load_json(PKG_ORIG))
        lines = []
        for name in self.reject_list:
            if not name:
                continue
            new_v = self.probe.get(name)
            old_v = old.get(name)
            if isinstance(new_v, str) and isinstance(old_v, str):
                lines.append(f"- **{name}**: `{old_v}` -> `{new_v}`")
        return "\n".join(lines)

    def write_outputs(self):
        details = self.reject_details()
        out_path = os.environ.get("GITHUB_OUTPUT")
        block = (
            f"attempts={self.final_attempt}\n"
            f"bisect_trials={self.trial_count}\n"
            f"test_outcome={self.test_outcome}\n"
            f"rejected={','.join(self.reject_list)}\n"
            f"reject_details<<EOF\n{details}\nEOF\n"
        )
        if out_path:
            with open(out_path, "a") as fh:
                fh.write(block)
        else:
            log("[no GITHUB_OUTPUT set - would have written:]")
            log(block)


def main():
    # Make sure the updater tool is available.
    run(["npm", "install", "-g", "npm-check-updates"], echo=True)

    # Backup the baseline.
    shutil.copy(PKG, PKG_ORIG)
    shutil.copy(LOCK, LOCK_ORIG)

    # Validate baseline JSON.
    try:
        load_json(PKG_ORIG)
    except (json.JSONDecodeError, OSError):
        die("Baseline package.json is not valid JSON - aborting")

    # Probe: capture every available bump up front.
    shutil.copy(PKG_ORIG, PROBE_FILE)
    rc, out = run(["ncu", "--packageFile", PROBE_FILE, "--target", TARGET, "--jsonUpgraded"])
    try:
        probe = json.loads(out) if rc == 0 and out.strip() else {}
        if not isinstance(probe, dict):
            probe = {}
    except json.JSONDecodeError:
        probe = {}
    log(f"Probe found {len(probe)} packages with available updates")

    baseline = load_json(PKG_ORIG)
    our_deps = set(all_deps(baseline).keys())
    scripts = baseline.get("scripts", {}) if isinstance(baseline.get("scripts"), dict) else {}
    has_build = "build" in scripts
    has_test = "test" in scripts

    updater = Updater(probe, our_deps, has_build, has_test)

    if not updater.run_loop():
        print(f"::error::Could not converge after {MAX_ATTEMPTS} attempts", flush=True)
        print(f"Final reject list: {','.join(updater.reject_list)}", flush=True)
        sys.exit(1)

    updater.write_outputs()


if __name__ == "__main__":
    main()
