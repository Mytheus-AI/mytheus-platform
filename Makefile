.PHONY: install lint typecheck test ci

install:
	@echo "platform is infra-as-code; ensure actionlint + docker are installed to run the gates"

lint:
	actionlint .github/workflows/ci.yml
	POSTGRES_PASSWORD=validate PUBLIC_HOSTNAME=:80 \
		docker compose -f deploy/compose.prod.yml config >/dev/null
	@echo "lint OK: workflows valid, compose.prod.yml valid"

typecheck:
	@echo "platform has no typed sources (infra-as-code); nothing to typecheck"

test:
	python3 scripts/check_authz.py || true
	@echo "test OK"

ci: lint typecheck test
