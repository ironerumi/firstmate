#!/usr/bin/env bash
# fm-aws-sso-refresh.sh - refresh an expired AWS IAM Identity Center session
# through one Firstmate-owned browser-local flow, then verify the resulting
# non-secret account and role identity.
#
# Usage:
#   fm-aws-sso-refresh.sh [--profile NAME] [--direnv-root ROOT]
#     [--config FILE] [--expected-account 123456789012]
#     [--expected-role ROLE] [--expected-start-url URL]
#     [--account-selector TEXT] [--browser-driver auto|browser-harness|agent-browser]
#     [--timeout SECONDS]
#
# Run from any project root. With --direnv-root, the command obtains the exact
# environment from `direnv exec ROOT env -0` before resolving AWS_PROFILE,
# AWS_CONFIG_FILE, and every child tool. Without it, ordinary AWS profiles and
# the caller's current environment are preserved. --profile overrides only the
# profile selection; this command never accepts or creates static credentials.
#
# Local configuration defaults to config/aws-sso-refresh.json beside this
# Firstmate home's tracked bin/ directory, or $FM_AWS_SSO_CONFIG when set. The
# file is gitignored and has this versioned shape (values below are fake):
#   {
#     "version": 1,
#     "defaults": {
#       "browserDriver": "browser-harness",
#       "browserHarnessName": "default"
#     },
#     "sessions": {
#       "example-session": {
#         "accountSelector": "saved-account-example",
#         "expectedStartUrl": "https://example.awsapps.com/start"
#       }
#     },
#     "profiles": {
#       "example-admin": {
#         "expectedAccount": "111122223333",
#         "expectedRole": "AdministratorAccess"
#       }
#     }
#   }
# defaults are overlaid by the resolved SSO-session entry, then profile entry,
# then explicit flags. Account and role normally come from the selected AWS SSO
# profile; expectedStartUrl normally comes from its SSO-session section. Private
# saved-account and browser selection belongs only in this local file or explicit
# invocation input, never in tracked instructions, defaults, fixtures, or docs.
# An expired session requires accountSelector or --account-selector; a still-valid
# identity can be verified without browser-local selection.
#
# The command first verifies cached credentials with sts get-caller-identity. It
# starts `aws sso login --no-browser --use-device-code` only for a recognized
# expired-session error. --use-device-code is explicit because a modern named
# sso_session otherwise routes the CLI through the PKCE authorization-code flow,
# which prints one /authorize URL with no device request to approve; only the
# device-code flow exposes the exact confirm-then-allow request this command is
# allowed to act on. An announced /authorize URL therefore stops for a human
# rather than being driven.
# AWS runs on a private PTY, so its decisive device state is drained immediately
# rather than hidden by a pipe or buffered background log. Only newline-complete
# output is parsed, and only the code-carrying verificationUriComplete is used;
# the bare verificationUri the CLI prints first lands on a code-entry page. A
# verification URL is recognized on a regional device.sso/oidc AWS host or on an
# origin exactly equal to the validated expectedStartUrl portal origin, because
# an Identity Center portal announces its device page as .../start/#/device with
# the user_code in the fragment; the code is read from either the query or that
# fragment, and a portal device page with no code stays bare. A verification URL
# on any other origin is the login-side login-url-unrecognized outcome, distinct
# from the browser-side unexpected-origin outcome for a page the owned tab
# actually reached. Once
# the login itself exits 0, the account/role identity check decides the outcome
# instead of leftover output. Raw login output is
# never relayed or persisted; device URLs/codes and token-shaped text stay inside
# the process. The verification URL reaches the browser adapter through a private
# mode-0600 file or stdin, never argv or an environment value.
#
# browser-harness is evaluated first. It is used only when its read-only doctor
# reports an already-live CDP attachment. The command then invokes the installed
# Browser Harness Python helpers directly, bypassing the CLI's auto-start and
# repair path so an attachment race cannot open or focus Chrome. The adapter
# creates one background tab, drives it with target-scoped CDP/DOM calls without
# Target.activateTarget, and closes only that owned tab. It never starts Chrome, enables remote debugging,
# moves the macOS pointer, emits global keyboard input, or changes the operator's
# active tab/window. It rejects Arc, unexpected origins, unverified request state,
# credential or MFA forms, and ambiguous saved-account choices.
#
# The installed agent-browser is evaluated second. Its current version-matched
# help exposes no verified background-tab/no-focus primitive, so this command
# refuses rather than activating a tab or launching an isolated browser. Any
# future adapter requires a separately implemented and empirically verified
# background target path; a new help flag alone cannot enable it. The legacy physical-browser
# recipe is not an automatic fallback. A separately coordinated, explicitly
# directed bounded recovery may use that established evidence, but this command
# never invokes physical computer control.
#
# Calls lock by the named SSO session, or by profile plus normalized start URL
# for legacy inline SSO configuration, not by project root. The same intended
# credential session serializes while distinct sessions remain concurrent even
# when they share one Identity Center portal.
# Waits are bounded. Signals and terminal outcomes stop the owned AWS/browser
# process groups and close only the owned tab; no browser, daemon, or unrelated
# login is killed or hijacked.
#
# Deterministic outcomes:
#   0   success (already valid or refreshed, account and role verified)
#   10  genuine human action required (credentials, MFA, ambiguous/wrong page,
#       missing safe attachment, or no verified no-focus browser channel)
#   11  timeout (lock, login, browser approval, or identity verification)
#   12  tool/configuration failure (missing/unsafe tools or config, non-SSO
#       profile, unexpected AWS failure, malformed output, or identity mismatch)
#
# Test-only adapter seams are FM_AWS_SSO_AWS_BIN,
# FM_AWS_SSO_BROWSER_ADAPTER, and FM_AWS_SSO_LOCK_DIR. Production callers should
# not set them. The browser adapter reads one private JSON request and emits one
# JSON object with status approved, human-action-required, timeout, or tool-error.
set -eu

usage() {
  sed -n '2,/^set -eu$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  echo "AWS SSO refresh tool/configuration failure: python3 is required" >&2
  exit 12
fi

FM_AWS_SSO_SCRIPT_PATH=$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
export FM_AWS_SSO_SCRIPT_PATH
exec python3 - "$@" <<'PY'
import argparse
import configparser
import errno
import fcntl
import hashlib
import json
import os
import pty
import re
import select
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse

SUCCESS = 0
HUMAN = 10
TIMEOUT = 11
TOOL = 12

AUTH_ERROR_MARKERS = (
    "token has expired and refresh failed",
    "sso session associated with this profile has expired",
    "the sso session associated with this profile has expired",
    "error loading sso token",
    "sso token has expired",
    "invalidgrantexception",
)

PUBLIC_REASONS = {
    "account-ambiguous": "saved-account selection is ambiguous",
    "account-not-saved": "the configured saved account is unavailable",
    "account-selection-unconfigured": "no private saved-account selector is configured",
    "agent-browser-no-background-tab": "agent-browser has no verified no-focus background-tab channel",
    "authorization-code-flow": "AWS used the browser authorization-code flow instead of the device request",
    "browser-application-unverified": "the attached browser is not verified as Google Chrome",
    "browser-attachment-required": "the signed-in Chrome attachment is unavailable",
    "browser-driver-missing": "no supported browser driver is installed",
    "credential-form": "the browser requires credential entry",
    "login-url-unrecognized": "AWS printed a verification page this command does not recognize",
    "mfa-required": "the browser requires MFA",
    "request-state-ambiguous": "the AWS device request state is ambiguous",
    "unexpected-origin": "the browser reached an unexpected origin",
}

BROWSER_HARNESS_PROGRAM = r"""
import json, os, re, signal, subprocess, sys, time
from urllib.parse import urlparse

request_path = os.environ.get("FM_AWS_SSO_REQUEST_FILE", "")
owned_target = None
result = {"status": "tool-error", "reason": "request-state-ambiguous"}
TERMINATION_SIGNALS = (signal.SIGTERM, signal.SIGHUP)

def emit(status, reason=""):
    global result
    result = {"status": status, "reason": reason}

# The parent terminates this adapter's process group on any failure of its own,
# so a default-disposition SIGTERM would skip the cleanup below and leave the
# operator's harness session cleared and the owned tab open. Raising instead
# routes termination through the existing finally blocks.
def terminated(_signum, _frame):
    raise KeyboardInterrupt

for handled_signal in TERMINATION_SIGNALS:
    signal.signal(handled_signal, terminated)

def restore_session(send, saved):
    # Best effort and itself uninterruptible: a termination signal is held
    # pending so it cannot abort the restore, and a failed restore never
    # replaces the status/reason already emitted.
    blocked = signal.pthread_sigmask(signal.SIG_BLOCK, TERMINATION_SIGNALS)
    try:
        send({"meta": "set_session", "session_id": saved})
    except BaseException:
        pass
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, blocked)

# Send a browser-target CDP call past the harness daemon's default page session.
# The daemon attaches a page session at startup and routes every non-Target.*
# call to it, which Chrome refuses for browser-only domains such as SystemInfo.
# The default session is cleared for these identity checks alone and restored
# immediately, so the operator's own harness state is unchanged. An unavailable
# bridge raises, which is the tool-error outcome: the attached browser's
# identity is never assumed.
def browser_target_call(method, **params):
    from browser_harness.helpers import _send as send
    saved = send({"meta": "session"}).get("session_id")
    if not saved:
        return cdp(method, **params)
    send({"meta": "set_session", "session_id": None})
    try:
        return cdp(method, **params)
    finally:
        restore_session(send, saved)

def runtime_value(session_id, expression):
    response = cdp(
        "Runtime.evaluate",
        session_id=session_id,
        expression=expression,
        returnByValue=True,
        awaitPromise=True,
    )
    if response.get("exceptionDetails"):
        raise RuntimeError("browser evaluation failed")
    return response.get("result", {}).get("value")

def snapshot(session_id):
    expression = r'''(() => {
      const visible = (e) => {
        const s = getComputedStyle(e);
        const r = e.getBoundingClientRect();
        return s.visibility !== 'hidden' && s.display !== 'none' && r.width > 0 && r.height > 0;
      };
      const controls = [...document.querySelectorAll('button,[role="button"],input,label,a')]
        .filter(visible)
        .map((e, i) => ({
          i,
          tag: e.tagName.toLowerCase(),
          type: (e.getAttribute('type') || '').toLowerCase(),
          role: (e.getAttribute('role') || '').toLowerCase(),
          text: (e.innerText || e.value || e.getAttribute('aria-label') || e.getAttribute('placeholder') || '').trim(),
          aria: (e.getAttribute('aria-label') || '').trim(),
          placeholder: (e.getAttribute('placeholder') || '').trim()
        }));
      return JSON.stringify({
        url: location.href,
        ready: document.readyState,
        text: (document.body && document.body.innerText || '').slice(0, 30000),
        controls
      });
    })()'''
    return json.loads(runtime_value(session_id, expression))

def click_control(session_id, index):
    expression = f'''(() => {{
      const visible = (e) => {{
        const s = getComputedStyle(e);
        const r = e.getBoundingClientRect();
        return s.visibility !== 'hidden' && s.display !== 'none' && r.width > 0 && r.height > 0;
      }};
      const controls = [...document.querySelectorAll('button,[role="button"],input,label,a')].filter(visible);
      const e = controls[{int(index)}];
      if (!e) return false;
      e.click();
      return true;
    }})()'''
    return bool(runtime_value(session_id, expression))

def normalized(value):
    return re.sub(r"\s+", " ", str(value or "")).strip().lower()

def matching_controls(page, needles):
    out = []
    for control in page.get("controls", []):
        haystack = normalized(" ".join((control.get("text", ""), control.get("aria", ""), control.get("placeholder", ""))))
        if any(normalized(needle) in haystack for needle in needles):
            out.append(control)
    return out

def exact_matching_controls(page, labels):
    expected = {normalized(label) for label in labels}
    out = []
    for control in page.get("controls", []):
        tag = control.get("tag")
        control_type = control.get("type")
        if not (
            tag == "button"
            or control.get("role") == "button"
            or (tag == "input" and control_type in ("button", "submit"))
        ):
            continue
        values = {
            normalized(control.get("text", "")),
            normalized(control.get("aria", "")),
            normalized(control.get("placeholder", "")),
        }
        if any(value and value in expected for value in values):
            out.append(control)
    return out

def allowed_verification_host(host):
    return bool(re.fullmatch(r"(?:device\.sso|oidc)\.[a-z0-9-]+\.amazonaws\.com", host or ""))

def url_origin(parsed):
    try:
        port = parsed.port
    except ValueError:
        return None
    host = (parsed.hostname or "").lower()
    if not host or parsed.username or parsed.password:
        return None
    return "%s://%s%s" % ((parsed.scheme or "").lower(), host, ":%d" % port if port else "")

def allowed_page_host(host, verification_host, portal_host):
    if host in (verification_host, portal_host):
        return True
    return bool(
        re.fullmatch(r"[a-z0-9-]+\.signin\.aws", host or "")
        or re.fullmatch(r"[a-z0-9-]+\.signin\.aws\.amazon\.com", host or "")
        or allowed_verification_host(host)
    )

try:
    with open(request_path, "r", encoding="utf-8") as handle:
        request = json.load(handle)
    verification = urlparse(request["verificationUrl"])
    portal = urlparse(request["expectedStartUrl"])
    # The portal is validated first because the verification URL may be accepted
    # only by deriving its allowed origin from that already-validated portal.
    if portal.scheme != "https" or not (portal.hostname or "").lower().endswith(".awsapps.com"):
        emit("human-action-required", "unexpected-origin")
        raise SystemExit
    verification_origin = url_origin(verification)
    portal_hosted = verification_origin is not None and verification_origin == url_origin(portal)
    if verification.scheme != "https" or not (
        allowed_verification_host((verification.hostname or "").lower()) or portal_hosted
    ):
        emit("human-action-required", "unexpected-origin")
        raise SystemExit

    version = browser_target_call("Browser.getVersion")
    version_text = " ".join(str(version.get(k, "")) for k in ("product", "userAgent", "jsVersion"))
    if "arc" in version_text.lower() or not str(version.get("product", "")).startswith("Chrome/"):
        emit("human-action-required", "browser-application-unverified")
        raise SystemExit
    if sys.platform == "darwin":
        process_info = browser_target_call("SystemInfo.getProcessInfo").get("processInfo", [])
        browser_pids = [str(p.get("id")) for p in process_info if p.get("type") == "browser" and p.get("id")]
        if len(browser_pids) != 1:
            emit("human-action-required", "browser-application-unverified")
            raise SystemExit
        command = subprocess.run(
            ["/bin/ps", "-p", browser_pids[0], "-o", "command="],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=3,
        ).stdout
        if "/Google Chrome.app/" not in command or "/Arc.app/" in command or "--user-data-dir=" in command:
            emit("human-action-required", "browser-application-unverified")
            raise SystemExit

    created = cdp("Target.createTarget", url="about:blank", background=True)
    owned_target = created.get("targetId")
    if not owned_target:
        raise RuntimeError("could not create background target")
    attached = cdp("Target.attachToTarget", targetId=owned_target, flatten=True)
    session_id = attached.get("sessionId")
    if not session_id:
        raise RuntimeError("could not attach background target")
    cdp("Page.enable", session_id=session_id)
    cdp("Runtime.enable", session_id=session_id)
    cdp("Page.navigate", session_id=session_id, url=request["verificationUrl"])

    deadline = time.monotonic() + float(request.get("timeoutSeconds", 180))
    selector = str(request.get("accountSelector") or "").strip()
    account_input_clicked = False
    account_input_clicked_at = None
    account_selected = False
    confirmed = False
    allowed = False
    unrecognized_since = None

    while time.monotonic() < deadline:
        page = snapshot(session_id)
        current = urlparse(page.get("url") or "")
        host = (current.hostname or "").lower()
        if current.scheme not in ("https", "about") or (
            current.scheme == "https"
            and not allowed_page_host(host, verification.hostname.lower(), portal.hostname.lower())
        ):
            emit("human-action-required", "unexpected-origin")
            break
        if page.get("ready") != "complete":
            time.sleep(0.25)
            continue

        text = normalized(page.get("text"))
        controls = page.get("controls", [])
        visible_password = [c for c in controls if c.get("tag") == "input" and c.get("type") == "password"]
        if visible_password:
            emit("human-action-required", "credential-form")
            break
        if any(token in text for token in ("multi-factor authentication", "authenticator app", "mfa", "ワンタイムパスワード", "多要素認証")):
            emit("human-action-required", "mfa-required")
            break

        if selector and not account_selected:
            matches = matching_controls(page, [selector])
            if len(matches) > 1:
                emit("human-action-required", "account-ambiguous")
                break
            if len(matches) == 1:
                if not click_control(session_id, matches[0]["i"]):
                    raise RuntimeError("saved account click failed")
                account_selected = True
                unrecognized_since = None
                time.sleep(0.4)
                continue

        username_inputs = []
        for control in controls:
            if control.get("tag") != "input" or control.get("type") not in ("", "text", "email"):
                continue
            label = normalized(" ".join((control.get("text", ""), control.get("aria", ""), control.get("placeholder", ""))))
            if any(token in label for token in ("user", "email", "account", "username", "ユーザー", "アカウント")):
                username_inputs.append(control)
        if username_inputs and not account_selected:
            if not selector:
                emit("human-action-required", "credential-form")
                break
            if len(username_inputs) != 1:
                emit("human-action-required", "account-not-saved")
                break
            if account_input_clicked:
                if time.monotonic() - account_input_clicked_at < 2:
                    time.sleep(0.25)
                    continue
                emit("human-action-required", "account-not-saved")
                break
            if not click_control(session_id, username_inputs[0]["i"]):
                raise RuntimeError("saved account input click failed")
            account_input_clicked = True
            account_input_clicked_at = time.monotonic()
            unrecognized_since = None
            time.sleep(0.4)
            continue

        # Exact labels only. An Identity Center portal labels its final grant
        # "Allow access"/"アクセスを許可" beside a "Deny access"/"アクセスを拒否"
        # control, so substring matching would be the unsafe way to cover it.
        confirm_matches = exact_matching_controls(page, ["confirm and continue", "確認して続行"])
        allow_matches = exact_matching_controls(page, ["allow", "許可", "allow access", "アクセスを許可"])
        if len(confirm_matches) > 1 or len(allow_matches) > 1:
            emit("human-action-required", "request-state-ambiguous")
            break
        if confirm_matches and not confirmed:
            if allow_matches:
                emit("human-action-required", "request-state-ambiguous")
                break
            if not click_control(session_id, confirm_matches[0]["i"]):
                raise RuntimeError("confirm click failed")
            confirmed = True
            unrecognized_since = None
            time.sleep(0.4)
            continue
        if allow_matches:
            if not confirmed or allowed:
                emit("human-action-required", "request-state-ambiguous")
                break
            if not click_control(session_id, allow_matches[0]["i"]):
                raise RuntimeError("allow click failed")
            allowed = True
            # Let the browser dispatch the final approval request before the
            # owned background tab closes. The parent still requires both AWS
            # CLI exit 0 and the account/role identity check.
            time.sleep(1.0)
            emit("approved")
            break

        if any(token in text for token in ("sign in", "signin", "サインイン")) and username_inputs:
            emit("human-action-required", "credential-form")
            break
        if unrecognized_since is None:
            unrecognized_since = time.monotonic()
        elif time.monotonic() - unrecognized_since >= 4:
            emit("human-action-required", "request-state-ambiguous")
            break
        time.sleep(0.25)
    else:
        emit("timeout")
except SystemExit:
    pass
except BaseException:
    emit("tool-error", "request-state-ambiguous")
finally:
    if owned_target:
        try:
            cdp("Target.closeTarget", targetId=owned_target)
        except BaseException:
            pass
    try:
        if request_path:
            os.unlink(request_path)
    except OSError:
        pass
    print(json.dumps(result, separators=(",", ":")))
"""


class Outcome(Exception):
    def __init__(self, code, reason):
        super().__init__(reason)
        self.code = code
        self.reason = reason


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


for handled_signal in (signal.SIGTERM, signal.SIGHUP):
    signal.signal(handled_signal, interrupted)


class QuietArgumentParser(argparse.ArgumentParser):
    # argparse's own usage/error text echoes the offending argv, which would put
    # the private saved-account selector into operator-visible output.
    def error(self, message):
        raise Outcome(TOOL, "invalid invocation")

    def exit(self, status=0, message=None):
        raise Outcome(TOOL, "invalid invocation")


def parser():
    p = QuietArgumentParser(add_help=False)
    p.add_argument("--profile")
    p.add_argument("--direnv-root")
    p.add_argument("--config")
    p.add_argument("--expected-account")
    p.add_argument("--expected-role")
    p.add_argument("--expected-start-url")
    p.add_argument("--account-selector")
    p.add_argument("--browser-driver", choices=("auto", "browser-harness", "agent-browser"))
    p.add_argument("--timeout", type=float, default=180.0)
    args = p.parse_args()
    if not (1 <= args.timeout <= 900):
        raise Outcome(TOOL, "timeout must be between 1 and 900 seconds")
    return args


def remaining(deadline, cap=None):
    value = deadline - time.monotonic()
    if value <= 0:
        raise Outcome(TIMEOUT, "operation timed out")
    return min(value, cap) if cap else value


def command_path(name, env):
    if not name or any(ch in name for ch in "\r\n\0"):
        return None
    if os.path.sep in name:
        path = os.path.abspath(os.path.expanduser(name))
        return path if os.path.isfile(path) and os.access(path, os.X_OK) else None
    return shutil.which(name, path=env.get("PATH"))


def effective_environment(args, deadline):
    env = dict(os.environ)
    if not args.direnv_root:
        return env, None
    root = os.path.realpath(os.path.expanduser(args.direnv_root))
    if not os.path.isdir(root):
        raise Outcome(TOOL, "direnv root is not a directory")
    direnv = command_path("direnv", env)
    if not direnv:
        raise Outcome(TOOL, "direnv is required for --direnv-root")
    try:
        proc = subprocess.run(
            [direnv, "exec", root, "env", "-0"],
            cwd=root,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=remaining(deadline, 20),
        )
    except subprocess.TimeoutExpired as exc:
        raise Outcome(TIMEOUT, "direnv environment load timed out") from exc
    if proc.returncode != 0:
        raise Outcome(TOOL, "direnv could not load the project environment")
    resolved = {}
    for entry in proc.stdout.split(b"\0"):
        if not entry or b"=" not in entry:
            continue
        key, value = entry.split(b"=", 1)
        resolved[key.decode(errors="surrogateescape")] = value.decode(errors="surrogateescape")
    if not resolved:
        raise Outcome(TOOL, "direnv returned an empty environment")
    return resolved, root


def read_aws_profile(env, profile, cwd):
    raw_path = os.path.expanduser(
        env.get("AWS_CONFIG_FILE")
        or os.path.join(env.get("HOME") or str(Path.home()), ".aws", "config")
    )
    if not os.path.isabs(raw_path):
        raw_path = os.path.join(cwd, raw_path)
    config_path = os.path.realpath(raw_path)
    cfg = configparser.RawConfigParser(interpolation=None)
    try:
        with open(config_path, "r", encoding="utf-8") as handle:
            cfg.read_file(handle)
    except (OSError, configparser.Error) as exc:
        raise Outcome(TOOL, "AWS configuration is missing or malformed") from exc
    section = "default" if profile == "default" else f"profile {profile}"
    if not cfg.has_section(section):
        raise Outcome(TOOL, "selected AWS profile does not exist")
    credentials_path = os.path.expanduser(
        env.get("AWS_SHARED_CREDENTIALS_FILE")
        or os.path.join(env.get("HOME") or str(Path.home()), ".aws", "credentials")
    )
    if not os.path.isabs(credentials_path):
        credentials_path = os.path.join(cwd, credentials_path)
    credentials_path = os.path.realpath(credentials_path)
    if os.path.exists(credentials_path):
        credentials = configparser.RawConfigParser(interpolation=None)
        try:
            with open(credentials_path, "r", encoding="utf-8") as handle:
                credentials.read_file(handle)
        except (OSError, configparser.Error) as exc:
            raise Outcome(TOOL, "AWS shared credentials configuration is malformed") from exc
        if credentials.has_section(profile):
            shared_values = {k: v.strip() for k, v in credentials.items(profile)}
            if any(shared_values.get(key) for key in (
                "aws_access_key_id", "aws_secret_access_key", "aws_session_token"
            )):
                raise Outcome(TOOL, "selected AWS profile also has static shared credentials")
    values = {k: v.strip() for k, v in cfg.items(section)}
    forbidden = (
        "aws_access_key_id",
        "aws_secret_access_key",
        "aws_session_token",
        "credential_process",
        "credential_source",
        "source_profile",
        "role_arn",
    )
    if any(values.get(key) for key in forbidden):
        raise Outcome(TOOL, "selected AWS profile is not a direct SSO profile")
    session_name = values.get("sso_session", "")
    session_values = {}
    if session_name:
        session_section = f"sso-session {session_name}"
        if not cfg.has_section(session_section):
            raise Outcome(TOOL, "selected AWS SSO session does not exist")
        session_values = {k: v.strip() for k, v in cfg.items(session_section)}
    start_url = session_values.get("sso_start_url") or values.get("sso_start_url")
    if not start_url:
        raise Outcome(TOOL, "selected AWS profile is not configured for SSO")
    return {
        "session": session_name,
        "start_url": start_url,
        "account": values.get("sso_account_id", ""),
        "role": values.get("sso_role_name", ""),
    }


def load_local_config(path):
    if not os.path.exists(path):
        return {"version": 1, "defaults": {}, "sessions": {}, "profiles": {}}
    try:
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise Outcome(TOOL, "local AWS SSO configuration must be a regular file")
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Outcome:
        raise
    except (OSError, ValueError) as exc:
        raise Outcome(TOOL, "local AWS SSO configuration is malformed") from exc
    if not isinstance(data, dict) or data.get("version") != 1:
        raise Outcome(TOOL, "local AWS SSO configuration version is unsupported")
    for key in ("defaults", "sessions", "profiles"):
        if not isinstance(data.get(key, {}), dict):
            raise Outcome(TOOL, f"local AWS SSO configuration field {key} must be an object")
    return data


def merged_settings(data, profile, session_name):
    merged = {}
    layers = [data.get("defaults", {})]
    if session_name:
        layers.append(data.get("sessions", {}).get(session_name, {}))
    layers.append(data.get("profiles", {}).get(profile, {}))
    for layer in layers:
        if not isinstance(layer, dict):
            raise Outcome(TOOL, "local AWS SSO profile/session entry must be an object")
        merged.update(layer)
    allowed = {
        "accountSelector",
        "expectedAccount",
        "expectedRole",
        "expectedStartUrl",
        "browserDriver",
        "browserHarnessName",
    }
    if any(key not in allowed for key in merged):
        raise Outcome(TOOL, "local AWS SSO configuration contains an unsupported field")
    if any(not isinstance(value, str) for value in merged.values()):
        raise Outcome(TOOL, "local AWS SSO configuration values must be strings")
    return merged


def normalize_start_url(value):
    parsed = urlparse(value)
    host = (parsed.hostname or "").lower()
    if parsed.scheme != "https" or not host.endswith(".awsapps.com") or parsed.username or parsed.password:
        raise Outcome(TOOL, "SSO start URL is not a verified Identity Center portal URL")
    path = (parsed.path or "/").rstrip("/") or "/"
    return f"https://{host}{path}"


def validate_settings(args, aws_profile, merged):
    configured_start = normalize_start_url(aws_profile["start_url"])
    expected_start = normalize_start_url(args.expected_start_url or merged.get("expectedStartUrl") or aws_profile["start_url"])
    if configured_start != expected_start:
        raise Outcome(TOOL, "configured and expected SSO start URLs do not match")
    account = args.expected_account or merged.get("expectedAccount") or aws_profile["account"]
    role = args.expected_role or merged.get("expectedRole") or aws_profile["role"]
    selector = args.account_selector or merged.get("accountSelector", "")
    driver = args.browser_driver or merged.get("browserDriver") or "auto"
    harness_name = merged.get("browserHarnessName") or "default"
    if not re.fullmatch(r"[0-9]{12}", account or ""):
        raise Outcome(TOOL, "expected AWS account must be a 12-digit account ID")
    if not re.fullmatch(r"[A-Za-z0-9+=,.@_/-]{1,128}", role or ""):
        raise Outcome(TOOL, "expected AWS role is missing or malformed")
    if selector and (len(selector) > 256 or any(ch in selector for ch in "\r\n\0")):
        raise Outcome(TOOL, "saved-account selector is malformed")
    if driver not in ("auto", "browser-harness", "agent-browser"):
        raise Outcome(TOOL, "browser driver is unsupported")
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", harness_name):
        raise Outcome(TOOL, "browser-harness connection name is malformed")
    return {
        "expected_start": expected_start,
        "account": account,
        "role": role,
        "selector": selector,
        "driver": driver,
        "harness_name": harness_name,
    }


def ensure_no_static_credentials(env):
    alternate_sources = (
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_WEB_IDENTITY_TOKEN_FILE",
        "AWS_ROLE_ARN",
        "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
        "AWS_CONTAINER_CREDENTIALS_FULL_URI",
    )
    if any(env.get(key) for key in alternate_sources):
        raise Outcome(TOOL, "alternate AWS credential environment variables are not accepted")


def safe_lock_dir(env):
    root = env.get("FM_AWS_SSO_LOCK_DIR") or os.path.join(tempfile.gettempdir(), f"firstmate-aws-sso-refresh-{os.getuid()}")
    root = os.path.realpath(os.path.expanduser(root))
    try:
        os.makedirs(root, mode=0o700, exist_ok=True)
        info = os.lstat(root)
    except OSError as exc:
        raise Outcome(TOOL, "could not create the AWS SSO lock directory") from exc
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_uid != os.getuid():
        raise Outcome(TOOL, "AWS SSO lock directory is unsafe")
    os.chmod(root, 0o700)
    return root


def acquire_lock(root, identity, deadline):
    digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()
    path = os.path.join(root, f"session-{digest}.lock")
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags, 0o600)
        info = os.fstat(fd)
    except OSError as exc:
        raise Outcome(TOOL, "AWS SSO session lock file is unsafe") from exc
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        os.close(fd)
        raise Outcome(TOOL, "AWS SSO session lock file is unsafe")
    os.fchmod(fd, 0o600)
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError as exc:
            if exc.errno not in (errno.EACCES, errno.EAGAIN):
                os.close(fd)
                raise Outcome(TOOL, "could not acquire the AWS SSO session lock") from exc
            if time.monotonic() >= deadline:
                os.close(fd)
                raise Outcome(TIMEOUT, "waiting for the same AWS SSO session timed out")
            time.sleep(0.1)


def aws_command(aws_bin, profile, *parts):
    return [aws_bin, *parts, "--profile", profile, "--no-cli-pager"]


def process_run(command, env, cwd, deadline, cap=20):
    try:
        return subprocess.run(
            command,
            cwd=cwd,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=remaining(deadline, cap),
        )
    except subprocess.TimeoutExpired as exc:
        raise Outcome(TIMEOUT, "AWS identity verification timed out") from exc


def identity_from_sts(aws_bin, profile, env, cwd, deadline):
    proc = process_run(
        aws_command(aws_bin, profile, "sts", "get-caller-identity", "--output", "json"),
        env,
        cwd,
        deadline,
    )
    if proc.returncode != 0:
        combined = (proc.stdout + b"\n" + proc.stderr).decode("utf-8", errors="replace").lower()
        if any(marker in combined for marker in AUTH_ERROR_MARKERS):
            return None, "expired"
        return None, "unexpected"
    try:
        data = json.loads(proc.stdout.decode("utf-8"))
        account = str(data["Account"])
        arn = str(data["Arn"])
    except (ValueError, KeyError, TypeError, UnicodeError):
        return None, "malformed"
    return {"account": account, "arn": arn}, "valid"


def actual_role(arn):
    match = re.match(r"^arn:[^:]+:sts::[0-9]{12}:assumed-role/([^/]+)/[^/]+$", arn)
    if match:
        return match.group(1)
    match = re.match(r"^arn:[^:]+:iam::[0-9]{12}:role/(.+)$", arn)
    return match.group(1).split("/")[-1] if match else ""


def verify_identity(identity, expected_account, expected_role):
    if identity["account"] != expected_account:
        raise Outcome(TOOL, "verified AWS account does not match the expected account")
    role = actual_role(identity["arn"])
    exact = role == expected_role or role.split("/")[-1] == expected_role
    reserved = role.startswith(f"AWSReservedSSO_{expected_role}_")
    if not (exact or reserved):
        raise Outcome(TOOL, "verified AWS role does not match the expected role")
    return role


def terminate_group(proc):
    if not proc or proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.wait(timeout=2)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass


def spawn_login(aws_bin, profile, env, cwd):
    master, slave = pty.openpty()
    child_env = dict(env)
    child_env["AWS_CLI_AUTO_PROMPT"] = "off"
    child_env["AWS_PAGER"] = ""
    proc = subprocess.Popen(
        aws_command(aws_bin, profile, "sso", "login", "--no-browser", "--use-device-code"),
        cwd=cwd,
        env=child_env,
        stdin=subprocess.DEVNULL,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
        close_fds=True,
    )
    os.close(slave)
    os.set_blocking(master, False)
    return proc, master


URL_PATTERN = re.compile(r"https://[^\s\x00-\x20<>\"']+")
DEVICE_HOST_PATTERN = re.compile(r"(?:device\.sso|oidc)\.[a-z0-9-]+\.amazonaws\.com")
USER_CODE_PATTERN = re.compile(r"[A-Za-z0-9._~-]{1,64}")
# The AWS CLI's no-browser handler announces each URL on its own line, so the
# line that follows one of these is positively the verification URL.
VERIFICATION_MARKERS = ("please visit the following url", "autofill the code upon loading")


def parent_url_origin(parsed):
    try:
        port = parsed.port
    except ValueError:
        return None
    host = (parsed.hostname or "").lower()
    if not host or parsed.username or parsed.password:
        return None
    return "%s://%s%s" % ((parsed.scheme or "").lower(), host, ":%d" % port if port else "")


def device_query(parsed):
    """Read device parameters from the query and from a fragment's query part.

    An Identity Center portal announces its device page as a client-routed
    fragment, /start/#/device?user_code=..., so the code lives outside the
    ordinary query. A real query value still wins over a fragment value.
    """
    values = parse_qs(parsed.query)
    marker = (parsed.fragment or "").find("?")
    if marker >= 0:
        for key, found in parse_qs(parsed.fragment[marker + 1:]).items():
            values.setdefault(key, found)
    return values


def device_url_kind(candidate, portal_origin=None):
    parsed = urlparse(candidate)
    portal_hosted = bool(portal_origin) and parent_url_origin(parsed) == portal_origin
    if parsed.scheme != "https" or not (
        DEVICE_HOST_PATTERN.fullmatch((parsed.hostname or "").lower()) or portal_hosted
    ):
        return None
    query = device_query(parsed)
    if (parsed.path or "").rstrip("/").endswith("/authorize") and query.get("response_type") == ["code"]:
        return "authorize"
    code = query.get("user_code", [""])[0]
    return "complete" if USER_CODE_PATTERN.fullmatch(code) else "bare"


def verification_url(buffer, ended, classify_end=True, portal_origin=None):
    """Pick the AWS verificationUriComplete out of newline-complete login output.

    The CLI prints the bare verificationUri first and the code-carrying
    verificationUriComplete only afterwards; the bare one lands on a code-entry
    page the adapter cannot recognize, so only a valid user_code query counts.
    Classification of anything else waits for a positively announced URL or for
    the end of output, so incidental URLs in AWS notices are not mistaken for
    the verification URL. classify_end=False suppresses only that end-of-output
    fallback, so a login that already exited 0 is settled by identity
    verification rather than by leftover output.
    """
    text = buffer.decode("utf-8", errors="replace")
    if not ended:
        cut = text.rfind("\n")
        if cut < 0:
            return None
        text = text[: cut + 1]
    complete = None
    saw_device = False
    saw_url = False
    announced = False
    for line in text.splitlines():
        candidates = [found.rstrip(".,);]") for found in URL_PATTERN.findall(line)]
        if not candidates:
            stripped = line.strip().lower()
            if any(marker in stripped for marker in VERIFICATION_MARKERS):
                announced = True
            elif stripped:
                announced = False
            continue
        saw_url = True
        kinds = [device_url_kind(candidate, portal_origin) for candidate in candidates]
        if complete is None and "complete" in kinds:
            complete = candidates[kinds.index("complete")]
        if announced and "authorize" in kinds and complete is None:
            # --use-device-code is always requested, so an announced PKCE
            # authorization-code URL means the CLI ignored it. That page has no
            # device request to approve, so it is never driven.
            raise Outcome(HUMAN, "authorization-code-flow")
        if any(kind for kind in kinds):
            saw_device = True
        elif announced:
            raise Outcome(HUMAN, "login-url-unrecognized")
        announced = False
    if complete:
        return complete
    if not ended or not classify_end:
        return None
    if saw_device:
        raise Outcome(HUMAN, "request-state-ambiguous")
    if saw_url:
        raise Outcome(HUMAN, "login-url-unrecognized")
    return None


def adapter_result(proc):
    stdout, _ = proc.communicate(timeout=1)
    try:
        lines = stdout[-65536:].decode("utf-8", errors="replace").splitlines()
        data = None
        for line in reversed(lines):
            try:
                candidate = json.loads(line)
            except ValueError:
                continue
            if isinstance(candidate, dict) and "status" in candidate:
                data = candidate
                break
        if not data:
            raise ValueError("missing result")
    except (ValueError, subprocess.TimeoutExpired):
        return {"status": "tool-error", "reason": "request-state-ambiguous"}
    status = data.get("status")
    reason = data.get("reason", "")
    if status not in ("approved", "human-action-required", "timeout", "tool-error"):
        return {"status": "tool-error", "reason": "request-state-ambiguous"}
    if reason and reason not in PUBLIC_REASONS:
        reason = "request-state-ambiguous"
    return {"status": status, "reason": reason}


def browser_harness_ready(executable, env, name, deadline):
    doctor_env = dict(env)
    doctor_env["BU_NAME"] = name
    doctor_env["BH_RECORD"] = "0"
    try:
        proc = subprocess.run(
            [executable, "doctor"],
            env=doctor_env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=remaining(deadline, 12),
        )
    except subprocess.TimeoutExpired:
        return False
    output = proc.stdout.decode("utf-8", errors="replace")
    return bool(re.search(r"\[ok\s*\]\s+active browser connections", output))


def browser_harness_python(executable, env):
    try:
        with open(executable, "rb") as handle:
            first_line = handle.readline(512).decode("utf-8", errors="strict").strip()
    except (OSError, UnicodeError):
        return None
    if not first_line.startswith("#!"):
        return None
    try:
        shebang = shlex.split(first_line[2:])
    except ValueError:
        return None
    if not shebang:
        return None
    if os.path.basename(shebang[0]) == "env":
        if len(shebang) != 2 or not shebang[1].startswith("python"):
            return None
        interpreter = command_path(shebang[1], env)
        return [interpreter] if interpreter else None
    interpreter = command_path(shebang[0], env)
    if not interpreter or "python" not in os.path.basename(interpreter).lower():
        return None
    # Preserve an ordinary direct-Python shebang option such as -s, but reject
    # compound launchers whose behavior would be less constrained than the
    # verified Browser Harness install surface.
    if any(not option.startswith("-") for option in shebang[1:]):
        return None
    return [interpreter, *shebang[1:]]


def write_private_request(lock_root, request):
    fd, path = tempfile.mkstemp(prefix="browser-request-", suffix=".json", dir=lock_root)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(request, handle, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(path)
        except OSError:
            pass
        raise
    return path


def spawn_browser_adapter(request, settings, env, lock_root, deadline):
    override = env.get("FM_AWS_SSO_BROWSER_ADAPTER")
    if override:
        try:
            command = shlex.split(override)
        except ValueError as exc:
            raise Outcome(TOOL, "test browser adapter command is malformed") from exc
        if not command or not command_path(command[0], env):
            raise Outcome(TOOL, "test browser adapter is unavailable")
        command[0] = command_path(command[0], env)
        proc = subprocess.Popen(
            command,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        proc.stdin.write(json.dumps(request, separators=(",", ":")).encode("utf-8"))
        proc.stdin.close()
        proc.stdin = None
        return proc, None

    wanted = settings["driver"]
    browser_harness = command_path("browser-harness", env)
    agent_browser = command_path("agent-browser", env)
    attachment_missing = False

    if wanted in ("auto", "browser-harness"):
        if browser_harness and browser_harness_ready(browser_harness, env, settings["harness_name"], deadline):
            harness_python = browser_harness_python(browser_harness, env)
            if not harness_python:
                raise Outcome(TOOL, "browser-harness install has no verified direct Python helper path")
            request_path = write_private_request(lock_root, request)
            adapter_env = dict(env)
            adapter_env["BU_NAME"] = settings["harness_name"]
            adapter_env["BH_RECORD"] = "0"
            adapter_env["FM_AWS_SSO_REQUEST_FILE"] = request_path
            direct_program = "from browser_harness.helpers import *\n" + BROWSER_HARNESS_PROGRAM
            proc = subprocess.Popen(
                [*harness_python, "-c", direct_program],
                env=adapter_env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return proc, request_path
        if browser_harness:
            attachment_missing = True
        elif wanted == "browser-harness":
            raise Outcome(TOOL, "browser-harness is not installed")

    if wanted in ("auto", "agent-browser"):
        if agent_browser:
            # Current agent-browser can attach with --cdp but tab new activates
            # the tab. No verified background/no-focus primitive means refusal;
            # only a separately implemented and verified adapter can lift this.
            raise Outcome(HUMAN, "agent-browser-no-background-tab")
        if wanted == "agent-browser":
            raise Outcome(TOOL, "agent-browser is not installed")

    if attachment_missing:
        raise Outcome(HUMAN, "browser-attachment-required")
    raise Outcome(TOOL, "browser-driver-missing")


def refresh_login(aws_bin, profile, env, cwd, settings, lock_root, deadline):
    login = None
    adapter = None
    adapter_request_path = None
    master = None
    raw = bytearray()
    found_url = None
    browser_state = None
    login_succeeded = False
    portal_origin = parent_url_origin(urlparse(settings["expected_start"]))
    try:
        login, master = spawn_login(aws_bin, profile, env, cwd)
        while True:
            now = time.monotonic()
            if now >= deadline:
                raise Outcome(TIMEOUT, "AWS SSO login timed out")
            if master is None:
                # Nothing left to select on; idle briefly instead of spinning
                # while the adapter finishes or the deadline arrives.
                time.sleep(min(0.05, deadline - now))
            else:
                try:
                    readable, _, _ = select.select([master], [], [], min(0.1, deadline - now))
                except (OSError, ValueError):
                    readable = []
                    time.sleep(min(0.05, deadline - now))
                if readable:
                    try:
                        chunk = os.read(master, 8192)
                    except OSError as exc:
                        if exc.errno == errno.EIO:
                            chunk = b""
                        else:
                            raise
                    if chunk:
                        raw.extend(chunk)
                        if len(raw) > 262144:
                            del raw[:-131072]
                    else:
                        os.close(master)
                        master = None
            login_status = login.poll()
            if login_status is not None and master is not None:
                # Drain the PTY after process exit without exposing its contents.
                for _ in range(8):
                    try:
                        chunk = os.read(master, 8192)
                    except OSError:
                        break
                    if not chunk:
                        break
                    raw.extend(chunk)
                os.close(master)
                master = None
            if login_status is not None:
                login_succeeded = login_status == 0
            # `master is None` means no further output can arrive, so this is the
            # end-of-output pass that may classify a missing or wrong device URL.
            # A login that already exited 0 skips that fallback and is settled by
            # the caller's account/role identity check instead.
            if found_url is None:
                found_url = verification_url(raw, master is None, not login_succeeded, portal_origin)
                if found_url:
                    request = {
                        "verificationUrl": found_url,
                        "expectedStartUrl": settings["expected_start"],
                        "accountSelector": settings["selector"],
                        "timeoutSeconds": max(1, int(deadline - time.monotonic())),
                    }
                    adapter, adapter_request_path = spawn_browser_adapter(
                        request, settings, env, lock_root, deadline
                    )
            if adapter is not None and adapter.poll() is not None and browser_state is None:
                browser_state = adapter_result(adapter)
                adapter = None
                if browser_state["status"] == "human-action-required":
                    raise Outcome(HUMAN, browser_state.get("reason") or "request-state-ambiguous")
                if browser_state["status"] == "timeout":
                    raise Outcome(TIMEOUT, "browser approval timed out")
                if browser_state["status"] == "tool-error":
                    raise Outcome(TOOL, "browser adapter could not verify the request")
            if login_status is not None and not login_succeeded:
                raise Outcome(TOOL, "AWS SSO login failed after the browser flow")
            if login_succeeded:
                # A truly silent AWS success is allowed as a disconfirming
                # counterfactual and is still identity-checked by the caller.
                # Once a device URL was issued, require this owned adapter to
                # report the approved request before accepting exit 0.
                if not found_url or (browser_state and browser_state["status"] == "approved"):
                    return
    finally:
        terminate_group(adapter)
        terminate_group(login)
        if master is not None:
            try:
                os.close(master)
            except OSError:
                pass
        if adapter_request_path:
            try:
                os.unlink(adapter_request_path)
            except OSError:
                pass
        # Drop all raw PTY bytes, including any device code or token-shaped text.
        for index in range(len(raw)):
            raw[index] = 0


def print_outcome(outcome):
    if outcome.code == HUMAN:
        detail = PUBLIC_REASONS.get(outcome.reason, "the request needs operator review")
        print(f"AWS SSO refresh requires human action: {detail}", file=sys.stderr)
    elif outcome.code == TIMEOUT:
        print("AWS SSO refresh timed out", file=sys.stderr)
    else:
        # Error strings are authored constants and never include captured child
        # output, config values, device state, or adapter stderr.
        print(f"AWS SSO refresh tool/configuration failure: {outcome.reason}", file=sys.stderr)


def main():
    args = parser()
    deadline = time.monotonic() + args.timeout
    env, direnv_root = effective_environment(args, deadline)
    ensure_no_static_credentials(env)
    profile = args.profile or env.get("AWS_PROFILE") or env.get("AWS_DEFAULT_PROFILE") or "default"
    if not re.fullmatch(r"[A-Za-z0-9+=,.@_-]{1,128}", profile):
        raise Outcome(TOOL, "AWS profile name is malformed")
    aws_bin = command_path(env.get("FM_AWS_SSO_AWS_BIN") or "aws", env)
    if not aws_bin:
        raise Outcome(TOOL, "AWS CLI is not installed")
    cwd = direnv_root or os.getcwd()
    aws_profile = read_aws_profile(env, profile, cwd)
    if args.config:
        config_path = os.path.realpath(os.path.expanduser(args.config))
    elif env.get("FM_AWS_SSO_CONFIG"):
        config_path = os.path.realpath(os.path.expanduser(env["FM_AWS_SSO_CONFIG"]))
    else:
        script_root = os.path.dirname(os.path.dirname(os.path.realpath(os.environ["FM_AWS_SSO_SCRIPT_PATH"])))
        config_path = os.path.join(script_root, "config", "aws-sso-refresh.json")
    data = load_local_config(config_path)
    merged = merged_settings(data, profile, aws_profile["session"])
    settings = validate_settings(args, aws_profile, merged)
    lock_root = safe_lock_dir(env)
    if aws_profile["session"]:
        lock_identity = f"sso-session:{aws_profile['session']}"
    else:
        lock_identity = f"legacy-profile:{profile}\0{settings['expected_start']}"
    lock_fd = acquire_lock(lock_root, lock_identity, deadline)
    try:
        identity, state = identity_from_sts(aws_bin, profile, env, cwd, deadline)
        if state == "valid":
            role = verify_identity(identity, settings["account"], settings["role"])
            print(f"AWS identity verified: account={identity['account']} role={role}")
            return SUCCESS
        if state != "expired":
            raise Outcome(TOOL, "AWS identity check failed for a reason other than expired SSO")
        if not settings["selector"]:
            raise Outcome(HUMAN, "account-selection-unconfigured")
        refresh_login(aws_bin, profile, env, cwd, settings, lock_root, deadline)
        identity, state = identity_from_sts(aws_bin, profile, env, cwd, deadline)
        if state != "valid":
            raise Outcome(TOOL, "AWS identity remained unavailable after SSO login")
        role = verify_identity(identity, settings["account"], settings["role"])
        print(f"AWS SSO refreshed and identity verified: account={identity['account']} role={role}")
        return SUCCESS
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)


try:
    code = main()
except Outcome as exc:
    print_outcome(exc)
    code = exc.code
except KeyboardInterrupt:
    print("AWS SSO refresh requires human action: operation interrupted", file=sys.stderr)
    code = HUMAN
except BaseException:
    # Never stringify an unexpected exception: it may contain child output,
    # request URLs, selectors, or environment values.
    print("AWS SSO refresh tool/configuration failure: unexpected internal error", file=sys.stderr)
    code = TOOL
raise SystemExit(code)
PY
