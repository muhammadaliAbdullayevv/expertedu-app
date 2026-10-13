from pydantic import BaseModel


class LoginRequest(BaseModel):
    phone: str
    password: str


class LoginResponse(BaseModel):
    token: str
    user_id: int
    role: str
    full_name: str
    phone: str


class MeResponse(BaseModel):
    user_id: int
    phone: str
    full_name: str
    role: str
