def test_high_5xx_recovery_query_treats_absent_error_series_as_zero():
    with open(
        "platform/manifests/demo-service.yaml.tpl",
        encoding="utf-8",
    ) as handle:
        text = handle.read()

    verify_line = next(
        line.strip()
        for line in text.splitlines()
        if line.strip().startswith("sre_verify_query:")
    )

    assert "or vector(0)" in verify_line
    assert 'status=~"5.."' in verify_line
    assert "sre_demo_requests_total[1m]" in verify_line
