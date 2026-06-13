import os

# meetingbot_config 在导入时校验核心凭据；测试环境提供占位值，
# 使测试套件无需真实 .env 即可运行。
os.environ.setdefault("FEISHU_APP_ID", "cli_testdummy0001")
os.environ.setdefault("FEISHU_APP_SECRET", "dummy_secret_for_tests")
os.environ.setdefault("HF_TOKEN", "hf_dummy_token_for_tests")
