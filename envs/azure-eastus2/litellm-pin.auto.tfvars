# Single source of truth for the deployed LiteLLM image. CI
# (scripts/Test-LitellmAdvisoryRange.py) checks this file. Non-secret by
# contract: tag + digest only. Re-verify on apply day (D-03); edits
# require a reviewed PR.
litellm_image_tag    = "v1.106.2"
litellm_image_digest = "sha256:7294b90f868c5c38c99b83021c7ba46f9b439e95f8e32964c925c7d2563a03f7"
