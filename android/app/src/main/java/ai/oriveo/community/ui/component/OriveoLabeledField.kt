package ai.oriveo.community.ui.component

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.theme.OriveoRadius
import ai.oriveo.community.ui.theme.opacity
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
fun OriveoLabeledField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "",
    isSecure: Boolean = false,
    footnote: String = "",
    enabled: Boolean = true,
    singleLine: Boolean = true,
    selectionRange: IntRange? = null,
    showLabel: Boolean = true,
) {
    val colors = OriveoTheme.colors
    var passwordVisible by remember { mutableStateOf(false) }
    var fieldValue by remember { mutableStateOf(TextFieldValue(value, selection = TextRange(value.length))) }
    LaunchedEffect(value, selectionRange) {
        if (fieldValue.text != value || selectionRange != null) {
            fieldValue = TextFieldValue(
                text = value,
                selection = selectionRange?.let { TextRange(it.first, it.last + 1) }
                    ?: TextRange(value.length),
            )
        }
    }

    Column(modifier = modifier.fillMaxWidth()) {
        if (showLabel) {
            Text(
                text = label,
                style = OriveoTheme.typography.caption,
                color = colors.textPrimary,
                maxLines = 1,
            )

            Spacer(modifier = Modifier.height(OriveoTheme.spacing.sm))
        }

        // TextField
        OutlinedTextField(
            value = fieldValue,
            onValueChange = {
                fieldValue = it
                onValueChange(it.text)
            },
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = OriveoTheme.layout.buttonHeight),
            enabled = enabled,
            singleLine = singleLine,
            placeholder = if (placeholder.isNotEmpty()) {
                { Text(text = placeholder, style = OriveoTheme.typography.body, color = colors.textTertiary) }
            } else null,
            textStyle = OriveoTheme.typography.body.copy(color = colors.textPrimary),
            visualTransformation = if (isSecure && !passwordVisible) {
                PasswordVisualTransformation()
            } else {
                VisualTransformation.None
            },
            trailingIcon = if (isSecure) {
                {
                    IconButton(onClick = { passwordVisible = !passwordVisible }) {
                        Icon(
                            imageVector = if (passwordVisible) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility,
                            contentDescription = if (passwordVisible) "Hide password" else "Show password",
                            tint = colors.textTertiary,
                        )
                    }
                }
            } else null,
            shape = RoundedCornerShape(10.dp),
            colors = OutlinedTextFieldDefaults.colors(
                focusedContainerColor = colors.surfaceInset,
                unfocusedContainerColor = colors.surfaceInset,
                disabledContainerColor = colors.surfaceInset,
                focusedBorderColor = colors.primary,
                unfocusedBorderColor = colors.border,
                disabledBorderColor = colors.border.opacity(0.5f),
                focusedTextColor = colors.textPrimary,
                unfocusedTextColor = colors.textPrimary,
                disabledTextColor = colors.textTertiary,
                cursorColor = colors.primary,
            ),
        )

        if (footnote.isNotEmpty()) {
            Spacer(modifier = Modifier.height(OriveoTheme.spacing.xs))
            Text(
                text = footnote,
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
                maxLines = 3,
            )
        }
    }
}
