from datetime import datetime

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


class CreateGroupRequest(BaseModel):
    name: str
    fee_amount: int
    due_day: int
    note: str | None = None


class UpdateGroupRequest(BaseModel):
    name: str | None = None
    fee_amount: int | None = None
    due_day: int | None = None
    note: str | None = None
    is_active: bool | None = None


class Group(BaseModel):
    id: int
    name: str
    fee_amount: int
    due_day: int
    is_active: bool
    note: str | None
    created_at: datetime


class CreateStudentRequest(BaseModel):
    full_name: str
    phone: str
    telegram_username: str | None = None
    note: str | None = None


class UpdateStudentRequest(BaseModel):
    full_name: str | None = None
    phone: str | None = None
    telegram_username: str | None = None
    note: str | None = None


class Student(BaseModel):
    id: int
    full_name: str
    phone: str
    telegram_username: str | None
    note: str | None
    created_at: datetime
