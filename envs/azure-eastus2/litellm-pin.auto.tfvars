# Single source of truth for the deployed LiteLLM image. CI
# (scripts/Test-LitellmAdvisoryRange.py) checks this file. Non-secret by
# contract: tag + digest only. Re-verify on apply day (D-03); edits
# require a reviewed PR.
litellm_image_tag    = "v1.106.7"
litellm_image_digest = "sha256:be24d7da11f4063ca23fbff6689bac5ded14fe4fc645e07f36588636969f1c27"
