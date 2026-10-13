from datetime import date, datetime

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
    teacher_name: str | None = None
    fee_amount: int
    due_day: int
    note: str | None = None


class UpdateGroupRequest(BaseModel):
    name: str | None = None
    teacher_name: str | None = None
    fee_amount: int | None = None
    due_day: int | None = None
    note: str | None = None
    is_active: bool | None = None


class Group(BaseModel):
    id: int
    name: str
    teacher_name: str | None
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


class CreateEnrollmentRequest(BaseModel):
    student_id: int
    group_id: int
    joined_at: date


class Enrollment(BaseModel):
    id: int
    student_id: int
    group_id: int
    joined_at: date
    status: str
    ended_at: date | None
    created_at: datetime


class RosterEntry(BaseModel):
    """One row on a group's roster -- an enrollment joined with its
    student's identity, since the roster screen never needs to look up
    the student separately. balance > 0 means the student owes money."""

    enrollment_id: int
    student_id: int
    student_full_name: str
    student_phone: str
    joined_at: date
    status: str
    balance: int


class StudentEnrollment(BaseModel):
    """One row on a student's profile -- the mirror of RosterEntry, joined
    with the group's identity instead."""

    enrollment_id: int
    group_id: int
    group_name: str
    joined_at: date
    status: str
    balance: int


class CreatePaymentRequest(BaseModel):
    amount: int
    note: str | None = None


class Transaction(BaseModel):
    id: int
    enrollment_id: int
    kind: str
    amount: int
    period_start: date | None
    due_date: date | None
    is_prorated: bool
    source: str
    note: str | None
    occurred_at: datetime
