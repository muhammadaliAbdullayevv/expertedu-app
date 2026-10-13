import os


class Settings:
    database_url: str = os.environ["DATABASE_URL"]
    jwt_secret: str = os.environ["JWT_SECRET"]
    jwt_expires_days: int = int(os.environ.get("JWT_EXPIRES_DAYS", "90"))

    eskiz_email: str | None = os.environ.get("ESKIZ_EMAIL") or None
    eskiz_password: str | None = os.environ.get("ESKIZ_PASSWORD") or None
    eskiz_from: str = os.environ.get("ESKIZ_FROM", "4546")
    eskiz_base_url: str = os.environ.get("ESKIZ_BASE_URL", "https://notify.eskiz.uz")

    fcm_service_account_json: str | None = os.environ.get("FCM_SERVICE_ACCOUNT_JSON") or None

    public_base_url: str = os.environ.get("PUBLIC_BASE_URL", "https://expertedu-api.ai-student-helper.site")

    @property
    def sms_configured(self) -> bool:
        return bool(self.eskiz_email and self.eskiz_password)

    @property
    def fcm_configured(self) -> bool:
        return bool(self.fcm_service_account_json)


settings = Settings()
