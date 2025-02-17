# Makefile

TARGET ?= dev
SERVICE_NAME ?= dbt
CMD ?= dbt-elementary
AIRFLOW_PATH = airflow_prj_name
DBT_PATH = dbt_prj_name
TF_PATH = airbyteprj_name
TF_PLAN = plan.cache

clean:
	@echo "\nCleaning dbt artifacts .."
	@uv run dbt clean --no-clean-project-files-only
	@echo "\nCleaning unused pre-commit cached repos. .."
	@uv run pre-commit gc


install:
	@echo "\nInstalling Dependencies .."
	@uv --version
	@uv lock --check
	@uv sync
	@echo "\nInstalling pre-commit hooks.."
	@uv run pre-commit install --install-hooks


tag:
	@echo "\nChecking commits .."
	@uv run cz bump
	@echo "\nGenerating changelog .."
	@uv run cz bump -ch

requirements:
	@echo "\nGenerating Python requirements .."
	@uv export --format=requirements-txt -o requirements.txt -q


test: requirements
	@echo "\nRunning sqlfluff .."
	@uv run sqlfluff fix --config ./.sqlfluff.cfg --show-lint-violations ./$(DBT_PATH)/
	@uv run sqlfluff lint --config ./.sqlfluff.cfg ./$(DBT_PATH)/
	@echo "\nStaging files .."
	@git add .
	@echo "\nRunning pre-commit hooks ..\n"
	@-uv run pre-commit run
	@echo "\nRestoring staged files ..\n"
	@git restore --staged . && git status


update: install
	@echo "\nUpdating dependencies .."
	@uv lock --upgrade
	@echo "\nUpdating pre-commit hooks .."
	@uv run pre-commit autoupdate


# DBT Commands

dbt-debug:
	@echo "\nDebugging profile config .."
	@uv run dbt debug --config-dir
	@uv run dbt debug


dbt-test:
	@echo "\nTesting dbt models .."
	@uv run dbt test --exclude "test_name:equality"


dbt-catalog: dbt-debug dbt-test
	@echo "\nBuilding catalog .."
	@uv run dbt docs generate --exclude "test_name:equality"
	@echo "\nOpening DBT documentation .."
	@uv run dbt docs serve --port 3000


dbt-run: dbt-debug
	@echo "\nRunning dbt with target '$(TARGET)' ..."
	@uv run dbt run --target $(TARGET)


dbt-elementary: dbt-test
	@echo "\nGenerating elementary report .."
	@uv run edr report --project-dir $(DBT_PROJECT_DIR) \
	--profiles-dir $(DBT_PROFILES_DIR) \
	--open-browser false --env $(TARGET) \
	--exclude-elementary-models true \
	--file-path /$(DBT_PATH)/report/index.html


dbt-pipeline: dbt-run dbt-test test dbt-elementary
	@echo "\nDBT pipeline completed !\n"


dbt-ci:
	@echo "Running dbt CI pipeline .."
	@echo "Exporting samples and expects data .."
	@uv run dbt seed --target=ci
	@echo "Running models based on mocked sources .."
	@uv run dbt run --select "models/*" --exclude "package:elementary" --target=ci
	@echo "Running ci tests .."
	@uv run dbt test --select "test_name:equality" --target=ci

# terraform & airbyte

tf-env: ENV_1 = dev
tf-env: ENV_2 = prod

tf-env:
	@echo "\nListing environments ..\n"
	@terraform -chdir=$(TF_PATH) workspace list
	@echo "Setting up Terraform environments .."
	@-terraform -chdir=$(TF_PATH) workspace new $(ENV_2)
	@-terraform -chdir=$(TF_PATH) workspace new $(ENV_1)

tf-build:
	@echo "\nYou're currently into `$(TARGET)` environment ..\n"
	@-terraform -chdir=$(TF_PATH) workspace select $(TARGET)
	@echo "\nInitializing Terraform ..\n"
	@terraform -chdir=$(TF_PATH) init
	@echo "Validating and Formatting code .."
	@terraform -chdir=$(TF_PATH) fmt
	@terraform -chdir=$(TF_PATH) validate
	@echo "Generating a plan .."
	@terraform -chdir=$(TF_PATH) plan -out=$(TF_PLAN)


tf-apply: tf-build
	@echo "\nThis command will fail if you're not connected to the VPN..\n"
	@echo "Deploying Airbyte resources ..\n"
	@terraform -chdir=$(TF_PATH) apply $(TF_PLAN)
	@sleep 3
	@echo "\nGenerating the AIRBYTE_CONN_ID env variable ..\n"
	@terraform -chdir=$(TF_PATH) output -raw connection_id > $(AIRFLOW_PATH)/.env
	@echo "\nTask completed, see : $(AIRFLOW_PATH)/.env \n"


tf-show:
	@echo "Checking if the project is deployed .."
	@terraform -chdir=$(TF_PATH) show
	@echo "\nState :\n"
	@terraform -chdir=$(TF_PATH) state list


tf-destroy: tf-show
	@echo "\nDestroying Airbyte resources ..\n"
	@terraform -chdir=$(TF_PATH) destroy

# docker-compose

comp-check:
	@echo "\nRunning Docker build checks ..\n"
	@docker build --check -f $(DBT_PATH)/dbt.dockerfile .
	@docker build --check -f airflow_blackbelt/airflow.dockerfile .
	@echo "\nChecking docker-compose consistency ..\n"
	@docker compose config --no-interpolate

comp-start: comp-check
	@echo "\nStarting docker-compose stack..\n"
	@docker compose up --build airflow-init
	@docker compose up -d

comp-clean:
	@echo "\nCleaning docker-compose stack ..\n"
	@docker compose down --volumes --rmi all
	@docker compose rm -f

comp-run:
	@echo "\nRunning $(SERVICE_NAME) container ..\n"
	@docker compose run --rm -it $(SERVICE_NAME) $(CMD)

comp-show:
	@echo "\nChecking docker-compose deployment ..\n"
	@docker compose ps -a

comp-clean-build-cache:
	@echo "\nListing build cache\n"
	@docker builder du
	@echo "\nCleaning docker-compose build cache ..\n"
	@docker builder prune --verbose
