from pathlib import Path


RULE_TEMPLATE = (
    Path(__file__).parents[1] / "platform" / "manifests" / "demo-service.yaml.tpl"
)


def test_high_5xx_recovery_query_treats_absent_error_series_as_zero():
    text = RULE_TEMPLATE.read_text()
    verify_line = next(
        line.strip()
        for line in text.splitlines()
        if line.strip().startswith("sre_verify_query:")
    )

    assert "or vector(0)" in verify_line
    assert 'status=~"5.."' in verify_line
    assert "sre_demo_requests_total[1m]" in verify_line
