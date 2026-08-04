.PHONY: plan apply test lint

plan:
	cd terraform && terraform plan

apply:
	cd terraform && terraform apply

test:
	pytest tests/ -v

lint:
	terraform fmt -check -recursive terraform/
