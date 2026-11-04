#!/usr/bin/env bash
# Fixed GPU watt value for the tests.
printf '%s\n' "${LLM_COST_TEST_WATTS:-200}"
