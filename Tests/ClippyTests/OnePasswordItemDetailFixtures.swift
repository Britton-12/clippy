/// Synthetic 1Password CLI JSON fixtures used by OnePasswordItemDetailTests.
/// These are hand-written; no real vault data is used.
enum OPFixtures {

    /// Login item with username, password (CONCEALED), and a TOTP field.
    static let loginWithTOTP = """
    {
      "id": "login001",
      "title": "My Web Login",
      "category": "LOGIN",
      "fields": [
        {"id":"username","label":"username","type":"STRING","purpose":"USERNAME","value":"alice@example.com"},
        {"id":"password","label":"password","type":"CONCEALED","purpose":"PASSWORD","value":"S3cr3tP@ss"},
        {"id":"totpfield","label":"one-time password","type":"OTP","value":"otpauth://totp/alice?secret=BASE32SECRET"}
      ]
    }
    """

    /// Item with multiple CONCEALED fields (e.g. an API credential with key + secret).
    static let multiConcealed = """
    {
      "id": "apicred001",
      "title": "Stripe API Keys",
      "category": "API_CREDENTIAL",
      "fields": [
        {"id":"username","label":"key ID","type":"STRING","value":"pk_live_XXXX"},
        {"id":"credential","label":"secret key","type":"CONCEALED","value":"sk_live_YYYY"},
        {"id":"restricted","label":"restricted key","type":"CONCEALED","value":"rk_live_ZZZZ"}
      ]
    }
    """

    /// Item with two custom sections and custom field labels.
    static let customSections = """
    {
      "id": "server001",
      "title": "Production Server",
      "category": "SERVER",
      "sections": [
        {"id":"ssh_section","label":"SSH"},
        {"id":"db_section","label":"Database"}
      ],
      "fields": [
        {"id":"hostname","label":"hostname","type":"STRING","value":"prod.example.com"},
        {"id":"ssh_user","label":"user","type":"STRING","value":"deploy",
         "section":{"id":"ssh_section","label":"SSH"}},
        {"id":"ssh_pass","label":"passphrase","type":"CONCEALED","value":"kP@ssphrase",
         "section":{"id":"ssh_section","label":"SSH"}},
        {"id":"db_host","label":"host","type":"STRING","value":"db.internal",
         "section":{"id":"db_section","label":"Database"}},
        {"id":"db_pass","label":"password","type":"CONCEALED","value":"dbSuperSecret",
         "section":{"id":"db_section","label":"Database"}}
      ]
    }
    """

    /// Minimal API credential with no sections; only non-concealed fields.
    static let apiCredentialNoSections = """
    {
      "id": "note001",
      "title": "AWS Account",
      "category": "API_CREDENTIAL",
      "fields": [
        {"id":"username","label":"Access Key ID","type":"STRING","value":"AKIAIOSFODNN7EXAMPLE"},
        {"id":"credential","label":"Secret Access Key","type":"CONCEALED","value":"wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"}
      ]
    }
    """

    /// Item with empty-value fields that should be preserved as nil value.
    static let emptyValueFields = """
    {
      "id": "empty001",
      "title": "Sparse Item",
      "category": "LOGIN",
      "fields": [
        {"id":"username","label":"username","type":"STRING","value":""},
        {"id":"password","label":"password","type":"CONCEALED","value":"real_pass"},
        {"id":"notes","label":"notes","type":"STRING"}
      ]
    }
    """

    /// Item whose section reference uses only the inline label (no top-level sections array).
    static let inlineSectionLabel = """
    {
      "id": "inline001",
      "title": "Inline Section Item",
      "category": "LOGIN",
      "fields": [
        {"id":"f1","label":"custom field","type":"STRING","value":"hello",
         "section":{"id":"sec_abc","label":"My Custom Section"}}
      ]
    }
    """
}
