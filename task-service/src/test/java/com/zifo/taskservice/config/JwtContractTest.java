package com.zifo.taskservice.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import org.junit.jupiter.api.Test;
import org.springframework.security.oauth2.jwt.JwtException;

/**
 * Contract test between the two services: these tokens were minted by auth-service's code path
 * (PyJWT, HS256) and must be accepted / rejected by task-service's decoder exactly as expected.
 * Regenerate with:  python -c "import jwt; print(jwt.encode({...}, SECRET, algorithm='HS256'))"
 */
class JwtContractTest {

    private static final String SECRET = "contract-test-secret-at-least-32-chars!!";

    // sub=1111..., email=alice@example.com, exp=2100-01-01
    private static final String VALID_PYJWT_TOKEN = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
            + "eyJzdWIiOiIxMTExMTExMS0xMTExLTExMTEtMTExMS0xMTExMTExMTExMTEiLCJlbWFpbCI6ImFsaWNlQGV4YW1wbGUuY29tIiwiaWF0IjoxNzYyNjQ2NDAwLCJleHAiOjQxMDI0NDQ4MDB9."
            + "tIWNbgPKyYrKAvaKbBOQkiypCf3w8NqGQwoe1eF7st4";

    // same claims but exp in 2020
    private static final String EXPIRED_PYJWT_TOKEN = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
            + "eyJzdWIiOiIxMTExMTExMS0xMTExLTExMTEtMTExMS0xMTExMTExMTExMTEiLCJlbWFpbCI6ImFsaWNlQGV4YW1wbGUuY29tIiwiaWF0IjoxNjAwMDAwMDAwLCJleHAiOjE2MDAwMDM2MDB9."
            + "lW38qTDZKyaLNyS8fkDlABE-9fYawWOgj-SOR179MOY";

    private final SecurityConfig config = new SecurityConfig();

    @Test
    void acceptsTokenIssuedByAuthService() {
        var jwt = config.jwtDecoder(SECRET).decode(VALID_PYJWT_TOKEN);
        assertThat(jwt.getSubject()).isEqualTo("11111111-1111-1111-1111-111111111111");
        assertThat(jwt.getClaimAsString("email")).isEqualTo("alice@example.com");
    }

    @Test
    void rejectsExpiredToken() {
        assertThatThrownBy(() -> config.jwtDecoder(SECRET).decode(EXPIRED_PYJWT_TOKEN))
                .isInstanceOf(JwtException.class);
    }

    @Test
    void rejectsTokenSignedWithAnotherSecret() {
        var decoder = config.jwtDecoder("a-completely-different-secret-of-32-plus-chars");
        assertThatThrownBy(() -> decoder.decode(VALID_PYJWT_TOKEN)).isInstanceOf(JwtException.class);
    }
}
