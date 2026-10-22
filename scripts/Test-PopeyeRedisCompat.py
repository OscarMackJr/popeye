"""Redis command-compat spike for Managed Redis clustering policy (GW-06).

Run INSIDE a gateway replica (the LiteLLM image ships the `redis` package):
    az containerapp exec -n <app> -g <rg>   then paste/run this script.

Reads REDIS_HOST, REDIS_PORT, REDIS_PASSWORD from the environment. Never
prints them; failures print only the exception class name.
"""
import os
import sys

PREFIX = "popeye:spike:"


def main() -> int:
    try:
        import redis
    except ImportError:
        print("FAIL: import redis: ImportError", file=sys.stderr)
        return 1

    try:
        client = redis.Redis(
            host=os.environ["REDIS_HOST"],
            port=int(os.environ.get("REDIS_PORT", "10000")),
            password=os.environ.get("REDIS_PASSWORD"),
            ssl=True,
        )
    except Exception as exc:
        print(f"FAIL: connect: {type(exc).__name__}", file=sys.stderr)
        return 1

    k = [f"{PREFIX}{n}" for n in ("a", "b", "c")]

    def incr() -> None:
        for key in k:
            client.incr(key)

    def pipeline() -> None:
        pipe = client.pipeline(transaction=True)
        pipe.incr(k[0])
        pipe.incr(k[1])
        pipe.execute()

    def mget() -> None:
        client.mget(k)

    def mset() -> None:
        client.mset({k[0]: 1, k[1]: 2})

    def lua() -> None:
        client.eval("return redis.call('INCR', KEYS[1])", 1, k[2])

    def scan() -> None:
        list(client.scan_iter(match=f"{PREFIX}*"))

    def cleanup() -> None:
        client.delete(*k)

    checks = [
        ("incr_three_keys", incr),
        ("multi_exec_two_keys", pipeline),
        ("mget_three_keys", mget),
        ("mset_two_keys", mset),
        ("eval_lua_one_key", lua),
        ("scan_prefix", scan),
        ("del_spike_keys", cleanup),
    ]
    failures = 0
    for name, fn in checks:
        try:
            fn()
            print(f"PASS: {name}")
        except Exception as exc:
            failures += 1
            print(f"FAIL: {name}: {type(exc).__name__}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
