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


class CreateSubjectRequest(BaseModel):
    name: str


class Subject(BaseModel):
    id: int
    name: str
    created_at: datetime


class SubjectWithCount(BaseModel):
    id: int
    name: str
    group_count: int
    created_at: datetime


class CreateGroupRequest(BaseModel):
    subject_id: int
    name: str
    teacher_id: int | None = None
    # Older app builds still send a typed name instead of teacher_id -- it's
    # matched to (or becomes) a teacher record, see routes/groups.py.
    teacher_name: str | None = None
    fee_amount: int
    due_day: int
    capacity: int | None = None
    note: str | None = None


class UpdateGroupRequest(BaseModel):
    subject_id: int | None = None
    name: str | None = None
    teacher_id: int | None = None
    fee_amount: int | None = None
    due_day: int | None = None
    # Null clears it (no seat limit).
    capacity: int | None = None
    note: str | None = None
    is_active: bool | None = None


class Group(BaseModel):
    id: int
    subject_id: int | None
    name: str
    teacher_id: int | None
    teacher_name: str | None
    fee_amount: int
    due_day: int
    capacity: int | None = None
    is_active: bool
    note: str | None
    created_at: datetime


class GroupWithStudentCount(Group):
    student_count: int


class GroupListItem(GroupWithStudentCount):
    """A group plus its subject's name -- for the desktop Settings table,
    which lists every group across all subjects."""

    subject_name: str | None


class CreateTeacherRequest(BaseModel):
    full_name: str
    phone: str | None = None
    note: str | None = None


class UpdateTeacherRequest(BaseModel):
    full_name: str | None = None
    phone: str | None = None
    note: str | None = None
    is_active: bool | None = None


class Teacher(BaseModel):
    id: int
    full_name: str
    phone: str | None
    note: str | None
    is_active: bool
    created_at: datetime


class TeacherListItem(Teacher):
    group_count: int


class CreateStudentRequest(BaseModel):
    full_name: str
    phone: str
    telegram_username: str | None = None
    note: str | None = None
    parent_phone: str | None = None
    heard_from: str | None = None


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
    parent_phone: str | None = None
    heard_from: str | None = None
    created_at: datetime


class StudentListItem(BaseModel):
    """Student plus their total balance across every enrollment -- only the
    list endpoint joins/aggregates this, so it's a separate model from
    [Student] rather than a field every other student response has to
    fake with 0."""

    id: int
    full_name: str
    phone: str
    telegram_username: str | None
    note: str | None
    created_at: datetime
    balance: int


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
    # Payments only; null for every payment recorded before methods existed.
    method: str | None = None
    occurred_at: datetime


class CreateInquiryRequest(BaseModel):
    full_name: str
    phone: str
    note: str | None = None
    subject_id: int | None = None
    trial_date: date | None = None


class UpdateInquiryRequest(BaseModel):
    note: str | None = None
    subject_id: int | None = None
    trial_date: date | None = None
    status: str | None = None


class Inquiry(BaseModel):
    id: int
    full_name: str
    phone: str
    note: str | None
    subject_id: int | None
    subject_name: str | None = None
    trial_date: date | None
    status: str
    converted_student_id: int | None
    created_at: datetime


class Debtor(BaseModel):
    """One enrollment that owes money -- per enrollment rather than per
    student, since a payment is always recorded against one enrollment.
    Withdrawn enrollments still appear: leaving doesn't clear a debt."""

    enrollment_id: int
    student_id: int
    student_full_name: str
    student_phone: str
    group_id: int
    group_name: str
    status: str
    balance: int
    oldest_unpaid_due: date | None


class TrialToday(BaseModel):
    inquiry_id: int
    full_name: str
    phone: str
    subject_name: str | None


class MonthlyRevenue(BaseModel):
    month: date
    amount: int


class RecentPayment(BaseModel):
    id: int
    enrollment_id: int
    student_full_name: str
    group_name: str
    amount: int
    occurred_at: datetime


class DashboardSummary(BaseModel):
    """Everything the desktop home screen shows, in one round trip. Dates and
    "this month" are the center's (see clock.py), not the server's."""

    today: date
    active_students: int
    new_students_this_month: int
    active_groups: int
    collected_this_month: int
    # What a full month brings in at current fees: the sum of every active
    # enrollment's group fee -- the yardstick for collected_this_month.
    monthly_plan: int
    total_debt: int
    debtor_count: int
    new_leads_this_week: int
    open_leads: int
    unanswered_leads: int
    due_today_count: int
    due_today_amount: int
    trials_today: list[TrialToday]
    revenue_by_month: list[MonthlyRevenue]
    recent_payments: list[RecentPayment]
    top_debtors: list[Debtor]


class CreateStudentWithEnrollmentRequest(BaseModel):
    """The "Yangi o'quvchi" dialog: a new student, added straight into a
    group, saved in one transaction (see routes/students.py)."""

    full_name: str
    phone: str
    group_id: int
    joined_at: date
    # 'prorated' (pay only for the days left in the current period) or
    # 'full' (a whole month's fee for it). Ignored when joined_at is the
    # group's due day itself -- both come to the full fee then.
    first_month: str = "prorated"
    discount_kind: str | None = None
    discount_value: int | None = None
    parent_phone: str | None = None
    heard_from: str | None = None
    note: str | None = None
    first_payment_amount: int | None = None
    first_payment_method: str | None = None


class StudentEnrolled(BaseModel):
    student: Student
    enrollment_id: int
    first_charge: int
    first_payment: int


class PhoneOwner(BaseModel):
    """Who already has a phone number -- the dialog's duplicate warning."""

    student_id: int
    full_name: str
    phone: str
    group_names: list[str]


class PhoneCheck(BaseModel):
    owner: PhoneOwner | None


class FirstChargePreview(BaseModel):
    """What the first charge would be, so the dialog can show both options
    before the user picks -- computed with the same code that charges."""

    monthly_fee: int
    discounted_fee: int
    period_start: date
    period_end: date
    days_left: int
    days_in_period: int
    prorated_amount: int
    full_amount: int
    # False when joining on the due day itself: prorated == full, no choice.
    is_mid_cycle: bool
