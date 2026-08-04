test:
	@test/run.sh

lint:
	@pre-commit run --all-files

hooks:
	@pre-commit install --install-hooks

update-hooks:
	@pre-commit autoupdate

.PHONY: test lint hooks update-hooks
